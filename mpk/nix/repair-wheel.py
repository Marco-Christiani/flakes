#!/usr/bin/env python3

import argparse
import fnmatch
import os
import shutil
import subprocess
import sys
import tempfile
import zlib
from collections.abc import Iterable
from pathlib import Path

from auditwheel.architecture import Architecture
from auditwheel.error import NonPlatformWheelError, WheelToolsError
from auditwheel.libc import Libc
from auditwheel.lddtree import LIBPYTHON_RE
from auditwheel.main_repair import logger
from auditwheel.patcher import Patchelf
from auditwheel.repair import repair_wheel
from auditwheel.wheel_abi import WheelAbIInfo, analyze_wheel_abi
from auditwheel.wheeltools import get_wheel_architecture, get_wheel_libc
from elftools.elf.dynamic import DynamicSection  # type: ignore
from elftools.elf.elffile import ELFFile  # type: ignore

NEVER_BUNDLE_PATTERNS = (
    "libcuda.so.1",
    "libnvidia-ml.so.1",
)


def run(*args: str, check: bool = True) -> str:
    proc = subprocess.run(
        list(args),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)
    return proc.stdout


def nix_sibling_outputs(path: str) -> list[str]:
    if not path.startswith("/nix/store/"):
        return []

    deriver = run("nix-store", "--query", "--deriver", path, check=False).strip()
    if not deriver or deriver == "unknown-deriver":
        return []

    outputs = run("nix-store", "--query", "--outputs", deriver, check=False)
    return [line.strip() for line in outputs.splitlines() if line.strip()]


def env_search_dirs() -> list[str]:
    value = os.environ.get("NIX_WHEEL_REPAIR_EXTRA_SEARCH_DIRS", "")
    return [item for item in value.split(":") if item]


def is_elf(path: Path) -> bool:
    try:
        with path.open("rb") as stream:
            ELFFile(stream)
        return True
    except Exception:
        return False


def runpaths(path: Path) -> list[str]:
    try:
        with path.open("rb") as stream:
            elf = ELFFile(stream)
            paths: list[str] = []
            for section in elf.iter_sections():
                if not isinstance(section, DynamicSection):
                    continue
                for tag in section.iter_tags("DT_RUNPATH"):
                    for item in tag.runpath.split(":"):
                        if item and item not in paths:
                            paths.append(item)
                for tag in section.iter_tags("DT_RPATH"):
                    for item in tag.rpath.split(":"):
                        if item and item not in paths:
                            paths.append(item)
            return paths
    except Exception:
        return []


def needed(path: Path) -> list[str]:
    try:
        with path.open("rb") as stream:
            elf = ELFFile(stream)
            libs: list[str] = []
            for section in elf.iter_sections():
                if not isinstance(section, DynamicSection):
                    continue
                for tag in section.iter_tags("DT_NEEDED"):
                    if tag.needed not in libs:
                        libs.append(tag.needed)
            return libs
    except Exception:
        return []


def resolve_soname(soname: str, search_dirs: Iterable[str]) -> Path | None:
    for directory in search_dirs:
        candidate = Path(directory) / soname
        if candidate.exists():
            return candidate
    return None


def normalized_excludes(excludes: Iterable[str]) -> frozenset[str]:
    return frozenset([*NEVER_BUNDLE_PATTERNS, *excludes])


def is_excluded_soname(soname: str, excludes: frozenset[str]) -> bool:
    return any(fnmatch.fnmatch(soname, pattern) for pattern in excludes)


def wheel_abi_for_repair(
    wheel_path: Path,
    excludes: frozenset[str],
    disable_isa_ext_check: bool,
    requested_policy_base_name: str,
) -> WheelAbIInfo:
    wheel_name = wheel_path.name

    try:
        arch: Architecture | None = get_wheel_architecture(wheel_name)
    except (WheelToolsError, NonPlatformWheelError):
        arch = None

    try:
        libc: Libc | None = get_wheel_libc(wheel_name)
    except WheelToolsError:
        libc = None

    return analyze_wheel_abi(
        libc,
        arch,
        wheel_path,
        excludes,
        disable_isa_ext_check=disable_isa_ext_check,
        allow_graft=True,
        requested_policy_base_name=requested_policy_base_name,
    )


def search_dirs_for_wheel(wheel_path: Path, wheel_abi: WheelAbIInfo) -> list[str]:
    search_dirs: list[str] = []

    for refs_by_policy in wheel_abi.full_external_refs.values():
        for external_ref in refs_by_policy.values():
            for source_path in external_ref.libs.values():
                if source_path is None:
                    continue
                for directory in [*runpaths(source_path), str(source_path.parent)]:
                    if directory not in search_dirs:
                        search_dirs.append(directory)

    for output in nix_sibling_outputs(str(wheel_path)):
        for candidate in (output, os.path.join(output, "lib")):
            if os.path.isdir(candidate) and candidate not in search_dirs:
                search_dirs.append(candidate)

    for candidate in env_search_dirs():
        if os.path.isdir(candidate) and candidate not in search_dirs:
            search_dirs.append(candidate)

    return search_dirs


def stage_resolved_libs(
    wheel_abi: WheelAbIInfo,
    search_dirs: list[str],
    stage_dir: Path,
    excludes: frozenset[str],
) -> dict[str, Path]:
    whitelist = system_whitelist_for_repair(wheel_abi)
    roots: list[tuple[str, Path]] = []

    for refs_by_policy in wheel_abi.full_external_refs.values():
        for external_ref in refs_by_policy.values():
            for soname, source_path in external_ref.libs.items():
                if source_path is not None:
                    continue
                if is_excluded_soname(soname, excludes):
                    continue
                resolved = resolve_soname(soname, search_dirs)
                if resolved is not None:
                    roots.append((soname, resolved))

    staged: dict[str, Path] = {}
    queue = list(roots)

    while queue:
        soname, source_path = queue.pop(0)
        if soname in staged:
            continue

        staged_path = stage_dir / soname
        shutil.copy2(os.path.realpath(source_path), staged_path)
        os.chmod(staged_path, 0o755)
        staged[soname] = staged_path

        child_search_dirs = [*runpaths(source_path), str(source_path.parent)]
        for child_soname in needed(source_path):
            if (
                is_excluded_soname(child_soname, excludes)
                or is_system_provided_soname(child_soname, whitelist)
                or child_soname in staged
            ):
                continue
            resolved = resolve_soname(
                child_soname, [str(stage_dir), *child_search_dirs, *search_dirs]
            )
            if resolved is not None and str(resolved.resolve()).startswith(
                "/nix/store/"
            ):
                queue.append((child_soname, resolved))

    return staged


def inject_staged_libs(wheel_abi: WheelAbIInfo, staged_libs: dict[str, Path]) -> None:
    for refs_by_policy in wheel_abi.full_external_refs.values():
        for external_ref in refs_by_policy.values():
            unresolved_present = any(
                path is None for path in external_ref.libs.values()
            )
            for soname, staged_path in staged_libs.items():
                if soname in external_ref.libs or unresolved_present:
                    external_ref.libs[soname] = staged_path


def choose_abis(wheel_abi: WheelAbIInfo) -> list[str]:
    policies = wheel_abi.policies

    if wheel_abi.overall_policy == policies.linux:
        requested_policy = policies.lowest
    else:
        requested_policy = wheel_abi.overall_policy

    abis = [requested_policy.name, *requested_policy.aliases]
    if requested_policy < wheel_abi.overall_policy:
        abis = [
            wheel_abi.overall_policy.name,
            *wheel_abi.overall_policy.aliases,
            *abis,
        ]

    return abis


def choose_requested_policy_name(
    wheel_abi: WheelAbIInfo, plat: str, only_plat: bool
) -> str:
    policies = wheel_abi.policies
    if plat == "auto":
        if wheel_abi.overall_policy == policies.linux:
            return policies.lowest.name
        return wheel_abi.overall_policy.name

    requested_policy = policies.get_policy_by_name(plat)
    if not only_plat and requested_policy < wheel_abi.overall_policy:
        return wheel_abi.overall_policy.name
    return requested_policy.name


def system_whitelist_for_repair(wheel_abi: WheelAbIInfo) -> frozenset[str]:
    repair_policy = wheel_abi.policies.get_policy_by_name(choose_abis(wheel_abi)[0])
    return repair_policy.whitelist


def is_system_provided_soname(soname: str, whitelist: frozenset[str]) -> bool:
    if "ld-linux" in soname or soname in {"ld64.so.1", "ld64.so.2"}:
        return True
    if LIBPYTHON_RE.match(soname):
        return True
    return soname in whitelist


def repair(
    wheel_path: Path,
    out_dir: Path,
    *,
    plat: str,
    lib_sdir: str,
    update_tags: bool,
    strip: bool,
    excludes: frozenset[str],
    only_plat: bool,
    disable_isa_ext_check: bool,
    zip_compression_level: int,
) -> Path | None:
    out_dir.mkdir(parents=True, exist_ok=True)

    wheel_abi = wheel_abi_for_repair(
        wheel_path,
        excludes,
        disable_isa_ext_check,
        plat,
    )
    search_dirs = search_dirs_for_wheel(wheel_path, wheel_abi)

    with tempfile.TemporaryDirectory() as stage_dir_name:
        stage_dir = Path(stage_dir_name)
        staged_libs = stage_resolved_libs(wheel_abi, search_dirs, stage_dir, excludes)
        inject_staged_libs(wheel_abi, staged_libs)

        patcher = Patchelf()
        requested_policy_name = choose_requested_policy_name(wheel_abi, plat, only_plat)
        requested_policy = wheel_abi.policies.get_policy_by_name(requested_policy_name)
        abis = [requested_policy.name, *requested_policy.aliases]
        return repair_wheel(
            wheel_abi,
            wheel_path,
            abis=abis,
            lib_sdir=lib_sdir,
            out_dir=out_dir.resolve(),
            update_tags=update_tags,
            patcher=patcher,
            strip=strip,
            zip_compression_level=zip_compression_level,
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Repair a Nix-built wheel by auto-discovering Nix store libraries and running auditwheel",
    )
    parser.add_argument("wheel_path", type=Path, help="Path to wheel file")
    parser.add_argument(
        "out_dir", type=Path, help="Output directory for repaired wheels"
    )
    parser.add_argument(
        "--plat",
        default="auto",
        help='Desired target platform policy base name or alias (default: "auto")',
    )
    parser.add_argument(
        "-L",
        "--lib-sdir",
        default=".libs",
        help='Subdirectory inside the wheel for grafted libraries (default: ".libs")',
    )
    parser.add_argument(
        "--no-update-tags",
        dest="update_tags",
        action="store_false",
        default=True,
        help="Do not rewrite wheel filename/WHEEL tags after repair",
    )
    parser.add_argument(
        "--strip",
        action="store_true",
        default=False,
        help="Strip symbols in the resulting wheel",
    )
    parser.add_argument(
        "--exclude",
        action="append",
        default=[],
        help="Exclude SONAME or glob pattern from grafting (can be repeated)",
    )
    parser.add_argument(
        "--only-plat",
        action="store_true",
        default=False,
        help="Do not automatically widen to the highest compatible policy",
    )
    parser.add_argument(
        "--disable-isa-ext-check",
        action="store_true",
        default=False,
        help="Do not check for extended ISA compatibility",
    )
    parser.add_argument(
        "-z",
        "--zip-compression-level",
        type=int,
        default=zlib.Z_DEFAULT_COMPRESSION,
        choices=list(range(zlib.Z_NO_COMPRESSION, zlib.Z_BEST_COMPRESSION + 1)),
        help="Zip compression level for the repaired wheel",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    wheel_path = args.wheel_path.resolve()
    out_dir = args.out_dir.resolve()
    out_wheel = repair(
        wheel_path,
        out_dir,
        plat=args.plat,
        lib_sdir=args.lib_sdir,
        update_tags=args.update_tags,
        strip=args.strip,
        excludes=normalized_excludes(args.exclude),
        only_plat=args.only_plat,
        disable_isa_ext_check=args.disable_isa_ext_check,
        zip_compression_level=args.zip_compression_level,
    )
    if out_wheel is not None:
        logger.info("Fixed-up wheel written to %s", out_wheel)
    return 0


raise SystemExit(main())
