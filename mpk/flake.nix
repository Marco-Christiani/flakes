{
  nixConfig = {
    extra-substituters = [
      "https://cuda-maintainers.cachix.org"
      "https://cache.nixos-cuda.org"
      "https://nix-community.cachix.org"
      "https://nixpkgs-python.cachix.org"
    ];
    extra-trusted-public-keys = [
      "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
      "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "nixpkgs-python.cachix.org-1:hxjI7pFxTyuTHn2NkvWCrAUcNZLNS3ZAvfYNuYifcEU="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    mirage-src = {
      url = "path:/home/marco/Github/mirage-ci-infra";
      flake = false;
    };
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs = {
        pyproject-nix.follows = "pyproject-nix";
        uv2nix.follows = "uv2nix";
        nixpkgs.follows = "nixpkgs";
      };
    };
  };

  outputs = {
    self,
    nixpkgs,
    mirage-src,
    pyproject-nix,
    uv2nix,
    pyproject-build-systems,
  }: let
    systems = ["x86_64-linux"];

    pythonVariants = [
      {
        name = "py310";
        pythonAttr = "python310";
        pythonTag = "cp310";
      }
      {
        name = "py311";
        pythonAttr = "python311";
        pythonTag = "cp311";
      }
      {
        name = "py312";
        pythonAttr = "python312";
        pythonTag = "cp312";
      }
    ];

    cudaVariants = [
      {
        name = "cuda12-1";
        cudaPackagesAttr = "cudaPackages_12_1";
      }
      {
        name = "cuda12-4";
        cudaPackagesAttr = "cudaPackages_12_4";
      }
      {
        name = "cuda12-6";
        cudaPackagesAttr = "cudaPackages_12_6";
      }
      {
        name = "cuda12-8";
        cudaPackagesAttr = "cudaPackages_12_8";
      }
      {
        name = "cuda12-9";
        cudaPackagesAttr = "cudaPackages_12_9";
      }
      {
        name = "cuda13-0";
        cudaPackagesAttr = "cudaPackages_13_0";
      }
    ];

    forAllSystems = f:
      builtins.listToAttrs (
        map (system: {
          name = system;
          value = f system;
        })
        systems
      );

    defaultPythonAttr = "python3";

    cudaTagFromPackagesAttr = cudaPackagesAttr:
      if cudaPackagesAttr == "cudaPackages_12_1"
      then "cu121"
      else if cudaPackagesAttr == "cudaPackages_12_4"
      then "cu124"
      else if cudaPackagesAttr == "cudaPackages_12_6"
      then "cu126"
      else if cudaPackagesAttr == "cudaPackages_12_8"
      then "cu128"
      else if cudaPackagesAttr == "cudaPackages_12_9"
      then "cu129"
      else if cudaPackagesAttr == "cudaPackages_13_0"
      then "cu130"
      else "";

    joinNameParts = parts:
      if parts == []
      then ""
      else "${builtins.concatStringsSep "-" parts}-";

    # "Release" or "Debug" -- applies to mirage-runtime CUDA/C++ build
    buildType = "Release";

    # Load uv workspace from mirage source (reads pyproject.toml + uv.lock)
    workspace = uv2nix.lib.workspace.loadWorkspace {workspaceRoot = mirage-src;};

    prefixAttrs = prefix: attrs:
      builtins.listToAttrs (
        map (name: {
          name = "${prefix}${name}";
          value = attrs.${name};
        }) (builtins.attrNames attrs)
      );

    variantSpecs =
      (map (pythonVariant: {
          nameParts = [pythonVariant.name];
          args = {inherit (pythonVariant) pythonAttr;};
        })
        pythonVariants)
      ++ (map (cudaVariant: {
          nameParts = [cudaVariant.name];
          args = {inherit (cudaVariant) cudaPackagesAttr;};
        })
        cudaVariants)
      ++ builtins.concatMap
      (pythonVariant:
        map (cudaVariant: {
          nameParts = [
            pythonVariant.name
            cudaVariant.name
          ];
          args = {
            inherit (pythonVariant) pythonAttr;
            inherit (cudaVariant) cudaPackagesAttr;
          };
        })
        cudaVariants)
      pythonVariants;

    mkVariantOutputs = mkFor: outputKind: system: let
      defaultOutput = (mkFor {inherit system;}).${outputKind};
    in
      builtins.foldl'
      (
        acc: variantSpec: let
          variantOutput =
            (mkFor {
                inherit system;
              }
              // variantSpec.args)
            .${
              outputKind
            };
        in
          acc // prefixAttrs (joinNameParts variantSpec.nameParts) variantOutput
      )
      defaultOutput
      variantSpecs;

    releaseMatrixEntries =
      builtins.concatMap
      (pythonVariant:
        map (cudaVariant: let
          prefix = joinNameParts [
            pythonVariant.name
            cudaVariant.name
          ];
        in {
          lane = builtins.concatStringsSep "-" [
            pythonVariant.name
            cudaVariant.name
          ];
          python = {
            name = pythonVariant.name;
            attr = pythonVariant.pythonAttr;
            tag = pythonVariant.pythonTag;
          };
          cuda = {
            name = cudaVariant.name;
            attr = cudaVariant.cudaPackagesAttr;
            tag = cudaTagFromPackagesAttr cudaVariant.cudaPackagesAttr;
          };
          packages = {
            wheel = "${prefix}mirage-python-wheel";
            wheelRaw = "${prefix}mirage-python-wheel-raw";
            wheelRepaired = "${prefix}mirage-python-wheel-repaired";
          };
          checks = {
            wheelRepaired = "${prefix}wheel-repaired";
            auditwheelShow = "${prefix}wheel-auditwheel-show";
          };
        })
        cudaVariants)
      pythonVariants;

    mkReleaseMatrix = system: let
      pkgs = import nixpkgs {inherit system;};
      jsonFile = pkgs.writeText "mpk-release-matrix.json" (builtins.toJSON releaseMatrixEntries);
      matrixApp = pkgs.writeShellApplication {
        name = "release-matrix";
        text = ''
          cat ${jsonFile}
        '';
      };
    in {
      packages.release-matrix-json = jsonFile;
      apps.release-matrix = {
        type = "app";
        program = "${matrixApp}/bin/release-matrix";
      };
    };

    mkFor = {
      system,
      cudaPackagesAttr ? "cudaPackages_12",
      pythonAttr ? defaultPythonAttr,
      gccHostAttr ? "gcc13",
    }: let
      pkgs = import nixpkgs {
        inherit system;
        config = {
          cudaSupport = true;
          allowUnfreePredicate =
            (import nixpkgs {inherit system;})._cuda.lib.allowUnfreeCudaPredicate;
        };
      };

      python3 =
        if builtins.hasAttr pythonAttr pkgs
        then builtins.getAttr pythonAttr pkgs
        else throw "Unsupported Python attribute `${pythonAttr}` for system `${system}`";

      inherit (pkgs) lib;

      cudaPackages = pkgs.${cudaPackagesAttr};
      gccHost = pkgs.${gccHostAttr};
      expectedCudaTag = cudaTagFromPackagesAttr cudaPackagesAttr;

      # Canonical Z3 provider for both native and Python build paths.
      #
      # TEMP(upstream): Mirage setup.py currently discovers Z3 through the
      # imported Python package, while our native runtime derivation used to
      # link against nixpkgs z3 directly. That split produced wheels with two
      # different libz3 providers. Use the locked z3-solver wheel payload as
      # the single source of truth until upstream offers a cleaner explicit
      # native-linkage contract.
      pythonBase = pkgs.callPackage pyproject-nix.build.packages {
        python = python3;
      };
      lockParityOverlay = workspace.mkPyprojectOverlay {sourcePreference = "wheel";};
      pythonSetPreMirage = pythonBase.overrideScope (
        lib.composeManyExtensions [
          pyproject-build-systems.overlays.default
          lockParityOverlay
        ]
      );
      mirageZ3 =
        if builtins.hasAttr "z3-solver" pythonSetPreMirage
        then pythonSetPreMirage."z3-solver"
        else throw "mirage-project requires z3-solver from the lock-resolved Python package set";

      wheelPythonDeps = ps:
        [
          ps.build
          ps.cython
          ps.setuptools
          ps.wheel
        ]
        ++ (
          if builtins.hasAttr "z3-solver" ps
          then [ps."z3-solver"]
          else if builtins.hasAttr "z3" ps
          then [ps.z3]
          else []
        );

      python310ForWheel =
        if pkgs ? python310
        then (pkgs.python310.withPackages wheelPythonDeps)
        else null;
      python311ForWheel = pkgs.python311.withPackages wheelPythonDeps;
      python312ForWheel = pkgs.python312.withPackages wheelPythonDeps;

      # -- Source filtering ------------------------------------------------
      #
      # Per-derivation source filtering so that e.g. editing a Python test
      # file doesn't rebuild CUDA.  cleanSourceWith uses builtins.path
      # which is content-addressed: if the filtered output is unchanged
      # the store path is the same and downstream builds are cached.
      #
      # Filters are composed (&&) not nested, because cleanSourceWith
      # unwraps nested sources to the original, breaking relative paths.

      srcStr = toString mirage-src;
      relPath = path: lib.removePrefix (srcStr + "/") (toString path);
      topDir = path: builtins.head (lib.splitString "/" (relPath path));

      baseFilter = path: type: let
        bn = baseNameOf (toString path);
      in
        !(builtins.elem bn ["build" ".direnv" "result" "__pycache__" ".mypy_cache" ".pytest_cache"]
          || (type == "regular" && lib.hasSuffix ".pyc" bn))
        && lib.cleanSourceFilter path type;

      mkSrc = name: extraFilter:
        lib.cleanSourceWith {
          inherit name;
          src = mirage-src;
          filter = path: type: baseFilter path type && extraFilter path type;
        };

      rustSrc = mkSrc "mirage-rust-src" (path: type: let
        rp = relPath path;
      in
        (type == "directory" && lib.hasPrefix rp "src/search/abstract_expr/abstract_subexpr")
        || lib.hasPrefix "src/search/abstract_expr/abstract_subexpr" rp
        || (type == "directory" && lib.hasPrefix rp "src/search/verification/formal_verifier_equiv")
        || lib.hasPrefix "src/search/verification/formal_verifier_equiv" rp);

      runtimeSrc = mkSrc "mirage-runtime-src" (path: _type: let
        rp = relPath path;
      in
        builtins.elem (topDir path) ["src" "include" "cmake"]
        || rp == "CMakeLists.txt"
        || rp == "config.cmake");

      # -- Native derivations ----------------------------------------------

      mirage-rust-libs = pkgs.callPackage ./nix/mirage-rust-libs.nix {
        src = rustSrc;
        inherit python3;
      };

      mirage-runtime = pkgs.callPackage ./nix/mirage-runtime.nix {
        inherit gccHost cudaPackages mirage-rust-libs buildType python3 mirageZ3;
        src = runtimeSrc;
      };

      # -- Python layer ----------------------------------------------------
      #
      # Python deps are resolved from uv.lock (generated by `uv lock` from
      # pyproject.toml [project.dependencies]).  uv2nix turns each locked
      # package into a Nix derivation fetched from PyPI as a wheel.
      # Artifact lineage matches what `uv sync` / `pip install` would resolve
      # from the same lock data, with explicit NixOS compatibility adjustments
      # applied in nix/python-layer.nix.
      #
      # Additional design notes and terminology are documented in:
      #   nix/python-packaging.md
      #
      # Project-native override scope is limited to mirage-project native
      # component injection (CUDA runtime, Rust cdylibs).

      pythonLayer = import ./nix/python-layer.nix {
        inherit
          pkgs
          lib
          pyproject-nix
          pyproject-build-systems
          workspace
          python3
          mirage-runtime
          mirage-rust-libs
          mirageZ3
          cudaPackages
          gccHost
          ;
      };

      inherit
        (pythonLayer)
        pythonSetBase
        pythonSet
        ;

      miragePython = pythonSetBase.mirage-project;
      mirageWheel = import ./nix/mirage-wheel.nix {
        inherit lib pkgs python3 miragePython mirageZ3 cudaPackages;
        mirageRuntime = mirage-runtime;
        mirageRustLibs = mirage-rust-libs;
      };

      # Runtime environment for end users (default dependency preset only).
      mirageEnv = pythonSet.mkVirtualEnv "mirage-env" workspace.deps.default;

      # Test/development environment (mirage-project with dev dependency-group).
      mirageDevEnv = pythonSet.mkVirtualEnv "mirage-dev-env" {
        mirage-project = ["dev"];
      };

      # -- Environments & helpers ------------------------------------------

      # Builds the Cython extension in-place and patches RPATH so the real
      # NVIDIA driver (/run/opengl-driver/lib) is found instead of the stub.
      mirage-build = pkgs.writeShellScriptBin "mirage-build" ''
        set -euo pipefail
        python setup.py build_ext --inplace
        for so in python/mirage/core.cpython-*.so; do
          origRpath=$(${pkgs.patchelf}/bin/patchelf --print-rpath "$so")
          ${pkgs.patchelf}/bin/patchelf --set-rpath "${pkgs.addDriverRunpath.driverLink}/lib:$origRpath" "$so"
          echo "patched RPATH: $so"
        done
      '';

      mirage-test = pkgs.writeShellScriptBin "mirage-test" ''
        exec ${mirageDevEnv}/bin/python -m pytest "$@"
      '';

      clean-build-dirs = pkgs.writeShellScriptBin "clean-build-dirs" ''
        find . -type d -name build -prune -exec rm -rf {} \;
      '';

      drun = pkgs.writeShellScriptBin "drun" ''
        # dont let host data leak, will break things
        find . -type d -name build -prune -exec rm -rf {} \;
        exec docker run --user "$(id -u)":"$(id -g)" --device nvidia.com/gpu=all --rm -it -v $PWD:/mirage:ro -w /mirage ''${1:-"nvidia/cuda:12.1.1-devel-ubuntu22.04"} bash
      '';

      run-act = pkgs.writeShellScriptBin "run-act" ''
        find . -type d -name build -prune -exec rm -rf {} \;
        act -W .github/workflows/build-test.yml --reuse -j test
      '';

      # Legacy container-based wheel builder retained for comparison and
      # fallback while the Nix-native raw/repaired wheel pipeline settles.
      legacy-build-wheel = pkgs.writeShellScriptBin "legacy-build-wheel" ''
        set -euo pipefail

        SRC="''${MIRAGE_SRC:-${toString mirage-src}}"
        MATRIX="$SRC/infra/wheels/matrix.json"
        SCRIPT="$SRC/infra/wheels/scripts/build-wheel.sh"
        PYTHON_TAG=""
        USER_CUDA_TAG=""
        EXPECTED_CUDA_TAG="${expectedCudaTag}"

        args=("$@")
        for ((i=0; i<''${#args[@]}; i++)); do
          if [[ "''${args[$i]}" == "--python" ]]; then
            next=$((i + 1))
            PYTHON_TAG="''${args[$next]:-}"
          elif [[ "''${args[$i]}" == "--cuda" ]]; then
            next=$((i + 1))
            USER_CUDA_TAG="''${args[$next]:-}"
          fi
        done

        if [[ -n "$EXPECTED_CUDA_TAG" && -n "$USER_CUDA_TAG" ]]; then
          echo "Do not pass --cuda for this target; lane is fixed to $EXPECTED_CUDA_TAG" >&2
          exit 2
        fi

        if [[ -z "''${MIRAGE_PYTHON_BIN:-}" && -n "$PYTHON_TAG" ]]; then
          case "$PYTHON_TAG" in
            cp310)
              export MIRAGE_PYTHON_BIN="${
          if python310ForWheel != null
          then "${python310ForWheel}/bin/python3.10"
          else ""
        }"
              ;;
            cp311)
              export MIRAGE_PYTHON_BIN="${python311ForWheel}/bin/python3.11"
              ;;
            cp312)
              export MIRAGE_PYTHON_BIN="${python312ForWheel}/bin/python3.12"
              ;;
          esac

          if [[ -z "$MIRAGE_PYTHON_BIN" ]]; then
            echo "No Nix Python interpreter available for $PYTHON_TAG in this nixpkgs revision" >&2
            exit 1
          fi
        fi

        if [[ ! -f "$MATRIX" ]]; then
          echo "Missing wheel matrix: $MATRIX" >&2
          exit 1
        fi
        if [[ ! -f "$SCRIPT" ]]; then
          echo "Missing wheel build script: $SCRIPT" >&2
          exit 1
        fi
        if [[ ! -f "$SRC/pyproject.toml" && ! -f "$SRC/setup.py" ]]; then
          echo "Source root does not look like a Python project: $SRC" >&2
          exit 1
        fi

        export CUDA_HOME="${cudaPackages.cudatoolkit}"
        export CUDACXX="${cudaPackages.cudatoolkit}/bin/nvcc"
        export PATH="${cudaPackages.cudatoolkit}/bin:${pkgs.auditwheel}/bin:$PATH"

        final_args=("$@")
        if [[ -n "$EXPECTED_CUDA_TAG" ]]; then
          final_args+=("--cuda" "$EXPECTED_CUDA_TAG")
        fi

        cd "$SRC"
        exec bash "$SCRIPT" "''${final_args[@]}"
      '';

      legacy-build-matrix = pkgs.writeShellScriptBin "legacy-build-matrix" ''
                set -euo pipefail

                SRC="''${MIRAGE_SRC:-${toString mirage-src}}"
                TARGET_SET="''${MATRIX_TARGET:-release}"
                OUT_DIR="''${OUT_DIR:-$PWD/dist/wheels}"

                usage() {
                  cat <<'EOF'
        Usage: legacy-build-matrix [--src <path>] [--target <release|pr>] [--out <dir>]

        Environment overrides:
          MIRAGE_SRC     Source checkout path
          MATRIX_TARGET  Matrix target set (default: release)
          OUT_DIR        Output wheel directory (default: ./dist/wheels)
        EOF
                }

                while [[ $# -gt 0 ]]; do
                  case "$1" in
                    --src)
                      SRC="''${2:-}"
                      shift 2
                      ;;
                    --target)
                      TARGET_SET="''${2:-}"
                      shift 2
                      ;;
                    --out)
                      OUT_DIR="''${2:-}"
                      shift 2
                      ;;
                    -h|--help)
                      usage
                      exit 0
                      ;;
                    *)
                      echo "Unknown argument: $1" >&2
                      usage
                      exit 2
                      ;;
                  esac
                done

                MATRIX="$SRC/infra/wheels/matrix.json"

                if [[ ! -f "$MATRIX" ]]; then
                  echo "Missing wheel matrix: $MATRIX" >&2
                  exit 1
                fi

                mapfile -t tuples < <(
                  ${pkgs.python3}/bin/python - "$MATRIX" "$TARGET_SET" "${expectedCudaTag}" <<'PY'
        import json
        import sys

        matrix_path = sys.argv[1]
        target_set = sys.argv[2]
        expected_cuda = sys.argv[3]
        with open(matrix_path, "r", encoding="utf-8") as fh:
            payload = json.load(fh)

        targets = payload.get("targets", {}).get(target_set, [])
        if not targets:
            raise SystemExit(f"No targets found for set '{target_set}'")

        for target in targets:
            if expected_cuda and target["cuda_tag"] != expected_cuda:
                continue
            print(f"{target['python']} {target['cuda_tag']}")
        PY
                )

                if [[ ''${#tuples[@]} -eq 0 ]]; then
                  echo "No matrix tuples matched target set '$TARGET_SET' for lane '${expectedCudaTag}'" >&2
                  exit 1
                fi

                mkdir -p "$OUT_DIR"
                for tuple in "''${tuples[@]}"; do
                  python_tag=''${tuple%% *}
                  cuda_tag=''${tuple##* }
                  echo "Building tuple python=$python_tag cuda=$cuda_tag"
                  ${legacy-build-wheel}/bin/legacy-build-wheel --python "$python_tag" --out "$OUT_DIR"
                done
      '';
    in {
      packages = {
        mirage-rust-libs-abstract-subexpr = mirage-rust-libs.abstract_subexpr;
        mirage-rust-libs-formal-verifier = mirage-rust-libs.formal_verifier;
        inherit mirage-runtime;
        mirage-python = miragePython;
        mirage-python-wheel-raw = mirageWheel.rawWheel;
        mirage-python-wheel-repaired = mirageWheel.auditwheelTools.repairedWheel;
        mirage-python-wheel = mirageWheel.auditwheelTools.repairedWheel;
        mirage-env = mirageEnv;
        mirage-dev-env = mirageDevEnv;
        default = miragePython;
      };

      checks = {
        # Smoke-test the Nix package artifact consumed by downstream users.
        package-import =
          pkgs.runCommand "mirage-package-import-check" {
            nativeBuildInputs = [mirageEnv];
          } ''
            export LD_LIBRARY_PATH="${cudaPackages.cudatoolkit}/lib/stubs"

            ${mirageEnv}/bin/python - <<'PY' > "$out"
            import mirage
            print(mirage.__file__)
            PY
          '';

        packaging =
          pkgs.runCommand "mirage-packaging-test" {
            nativeBuildInputs = [mirageDevEnv];
          } ''
            set -o pipefail

            # No GPU driver in sandbox - use CUDA stubs for libcuda.so
            export LD_LIBRARY_PATH="${cudaPackages.cudatoolkit}/lib/stubs"

            python -m pytest -m "not impure" -p no:cacheprovider -v \
              ${mirage-src}/tests/python/test_packaging.py 2>&1 | tee $out
          '';

        # Guard rails for lock-parity expectations:
        # ensure key CUDA-related distributions match uv.lock exactly.
        lock-parity =
          pkgs.runCommand "mirage-lock-parity-check" {
            nativeBuildInputs = [mirageEnv];
          } ''
            ${mirageEnv}/bin/python - <<'PY' > "$out"
            import importlib.metadata as md
            import json
            import tomllib
            from pathlib import Path

            lock_path = Path("${mirage-src}/uv.lock")
            lock_data = tomllib.loads(lock_path.read_text())

            target_candidates = {
                "torch": ["torch"],
                "triton": ["triton"],
                "nvidia-cublas": ["nvidia-cublas", "nvidia-cublas-cu12"],
                "nvidia-cuda-cupti": ["nvidia-cuda-cupti", "nvidia-cuda-cupti-cu12"],
                "nvidia-cuda-nvrtc": ["nvidia-cuda-nvrtc", "nvidia-cuda-nvrtc-cu12"],
                "nvidia-cuda-runtime": ["nvidia-cuda-runtime", "nvidia-cuda-runtime-cu12"],
                "nvidia-cudnn": ["nvidia-cudnn-cu13", "nvidia-cudnn-cu12"],
                "nvidia-cufft": ["nvidia-cufft", "nvidia-cufft-cu12"],
                "nvidia-cufile": ["nvidia-cufile", "nvidia-cufile-cu12"],
                "nvidia-curand": ["nvidia-curand", "nvidia-curand-cu12"],
                "nvidia-cusolver": ["nvidia-cusolver", "nvidia-cusolver-cu12"],
                "nvidia-cusparse": ["nvidia-cusparse", "nvidia-cusparse-cu12"],
                "nvidia-cusparselt": ["nvidia-cusparselt-cu13", "nvidia-cusparselt-cu12"],
                "nvidia-nccl": ["nvidia-nccl-cu13", "nvidia-nccl-cu12"],
                "nvidia-nvjitlink": ["nvidia-nvjitlink", "nvidia-nvjitlink-cu12"],
                "nvidia-nvshmem": ["nvidia-nvshmem-cu13", "nvidia-nvshmem-cu12"],
                "nvidia-nvtx": ["nvidia-nvtx", "nvidia-nvtx-cu12"],
            }

            lock_versions_all = {p["name"]: p["version"] for p in lock_data["package"]}

            resolved = {}
            missing_from_lock = []
            for key, candidates in target_candidates.items():
                selected = next((name for name in candidates if name in lock_versions_all), None)
                if selected is None:
                    missing_from_lock.append({"target": key, "candidates": candidates})
                else:
                    resolved[key] = {
                        "dist": selected,
                        "version": lock_versions_all[selected],
                    }

            if missing_from_lock:
                raise SystemExit(
                    "Missing expected package families in uv.lock: "
                    + json.dumps(missing_from_lock, indent=2, sort_keys=True)
                )

            mismatches = {}
            for key, info in resolved.items():
                name = info["dist"]
                expected = info["version"]
                actual = md.version(name)
                if actual != expected:
                    mismatches[key] = {
                        "dist": name,
                        "expected": expected,
                        "actual": actual,
                    }

            if mismatches:
                raise SystemExit("Version mismatch against uv.lock: " + json.dumps(mismatches, indent=2, sort_keys=True))

            print(json.dumps(resolved, indent=2, sort_keys=True))
            PY
          '';

        # Build-time runtime sanity check for CUDA wheel layout and torch metadata.
        # This does not require a real GPU in sandbox.
        torch-runtime-metadata =
          pkgs.runCommand "mirage-torch-runtime-metadata" {
            nativeBuildInputs = [mirageEnv];
          } ''
            export LD_LIBRARY_PATH="${cudaPackages.cudatoolkit}/lib/stubs"

            ${mirageEnv}/bin/python - <<'PY' > "$out"
            import importlib.metadata as md
            import json
            from pathlib import Path
            import sys
            import torch

            report = {
                "torch_version": torch.__version__,
                "torch_dist_version": md.version("torch"),
                "torch_cuda": torch.version.cuda,
                "torch_file": str(Path(torch.__file__).resolve()),
            }

            normalized_torch_version = report["torch_version"].split("+", 1)[0]
            if normalized_torch_version != report["torch_dist_version"]:
                raise SystemExit(f"torch.__version__ mismatch: {report}")
            if report["torch_cuda"] is None:
                raise SystemExit(f"Expected CUDA-enabled torch wheel metadata, got: {report}")

            expected_layout = {
                "cudart": [
                    "nvidia/cuda_runtime/lib/libcudart.so*",
                    "nvidia/cu13/lib/libcudart.so*",
                    "nvidia/cu12/lib/libcudart.so*",
                ],
                "cublas": [
                    "nvidia/cublas/lib/libcublas.so*",
                    "nvidia/cu13/lib/libcublas.so*",
                    "nvidia/cu12/lib/libcublas.so*",
                ],
                "cudnn": [
                    "nvidia/cudnn/lib/libcudnn.so*",
                    "nvidia/cu13/lib/libcudnn.so*",
                    "nvidia/cu12/lib/libcudnn.so*",
                ],
                "nccl": [
                    "nvidia/nccl/lib/libnccl.so*",
                    "nvidia/cu13/lib/libnccl.so*",
                    "nvidia/cu12/lib/libnccl.so*",
                ],
                "nvjitlink": [
                    "nvidia/nvjitlink/lib/libnvJitLink.so*",
                    "nvidia/cu13/lib/libnvJitLink.so*",
                    "nvidia/cu12/lib/libnvJitLink.so*",
                ],
                "torch_cuda": ["torch/lib/libtorch_cuda.so*"],
            }

            search_roots = []
            for entry in sys.path:
                p = Path(entry)
                if p.name == "site-packages":
                    search_roots.append(p)

            # fallback for editable/symlinked contexts
            search_roots.append(Path(torch.__file__).resolve().parents[1])

            resolved = {}
            missing = {}
            for key, patterns in expected_layout.items():
                matches = []
                for root in search_roots:
                    for pattern in patterns:
                        matches.extend(sorted(root.glob(pattern)))
                if not matches:
                    missing[key] = patterns
                    continue
                resolved[key] = str(matches[0])

            if missing:
                nvidia_layout = {}
                for root in search_roots:
                    nvidia_root = root / "nvidia"
                    if nvidia_root.is_dir():
                        nvidia_layout[str(root)] = sorted(
                            entry.name
                            for entry in nvidia_root.iterdir()
                            if entry.is_dir()
                        )

                debug = {
                    "missing": missing,
                    "search_roots": [str(p) for p in search_roots],
                    "nvidia_subdirs": nvidia_layout,
                }
                raise SystemExit(
                    "Missing expected CUDA wheel artifacts: "
                    + json.dumps(debug, indent=2, sort_keys=True)
                )

            report["resolved_artifacts"] = resolved
            print(json.dumps(report, indent=2, sort_keys=True))
            PY
          '';

        wheel-auditwheel-show = mirageWheel.auditwheelTools.showReport;
        wheel-repaired = mirageWheel.auditwheelTools.repairedWheel;
      };

      apps = {
        test = {
          type = "app";
          program = "${mirage-test}/bin/mirage-test";
        };

        legacy-build-wheel = {
          type = "app";
          program = "${legacy-build-wheel}/bin/legacy-build-wheel";
        };

        legacy-build-matrix = {
          type = "app";
          program = "${legacy-build-matrix}/bin/legacy-build-matrix";
        };

        auditwheel-show = {
          type = "app";
          program = "${mirageWheel.auditwheelTools.showApp}/bin/mirage-auditwheel-show";
        };

        repair-wheel = {
          type = "app";
          program = "${mirageWheel.auditwheelTools.repairWheelApp}/bin/mirage-repair-wheel";
        };
      };

      devShells.default = pkgs.mkShell {
        packages = [
          pkgs.cmake
          pkgs.gnumake
          gccHost
          pkgs.pkg-config
          pkgs.git
          cudaPackages.cudatoolkit
          cudaPackages.cuda_cudart
          pkgs.rustc
          pkgs.cargo
          mirageZ3
          mirageDevEnv
          pkgs.autoAddDriverRunpath

          # dev tools
          pkgs.pyright
          pkgs.ruff
          pkgs.ty
          pkgs.mypy
          pkgs.act
          pkgs.uv

          # interactive dev conveniences
          mirage-build
          clean-build-dirs
          drun
          run-act
        ];

        env = {
          CUDA_HOME = "${cudaPackages.cudatoolkit}";
          CUDACXX = "${cudaPackages.cudatoolkit}/bin/nvcc";
          CC = "${gccHost}/bin/gcc";
          CXX = "${gccHost}/bin/g++";
          Z3_LIBRARY_PATH = "${mirageZ3}/${python3.sitePackages}/z3/lib";
          LIBRARY_PATH = "${cudaPackages.cudatoolkit}/lib/stubs";
        };

        shellHook = ''
          echo "mirage devShell"
          echo "  CUDA:   $(nvcc --version 2>/dev/null | grep release | head -1)"
          echo "  GCC:    $(${gccHost}/bin/gcc --version | head -1)"
          echo "  Rust:   $(rustc --version)"
          echo "  Python: $(python3 --version)"
          export MIRAGE_HOME="$PWD"

          # Editable install: make `import mirage` use the source tree
          export PYTHONPATH="$PWD/python''${PYTHONPATH:+:$PYTHONPATH}"

          # Symlink pre-built Rust .so into the layout __init__.py expects
          mkdir -p build/abstract_subexpr/release build/formal_verifier/release
          ln -sfn ${mirage-rust-libs.abstract_subexpr}/lib/libabstract_subexpr.so build/abstract_subexpr/release/
          ln -sfn ${mirage-rust-libs.formal_verifier}/lib/libformal_verifier.so build/formal_verifier/release/

          if ! compgen -G "$PWD/python/mirage/core.cpython-*.so" > /dev/null 2>&1; then
            echo ""
            echo "  Cython extension not built. Run: mirage-build"
          fi
        '';
      };
    };
  in {
    packages = forAllSystems (
      s:
        (mkVariantOutputs mkFor "packages" s)
        // (mkReleaseMatrix s).packages
    );

    checks = forAllSystems (s: mkVariantOutputs mkFor "checks" s);

    apps = forAllSystems (
      s:
        (mkVariantOutputs mkFor "apps" s)
        // (mkReleaseMatrix s).apps
    );
    devShells = forAllSystems (s: (mkFor {system = s;}).devShells);
    formatter = forAllSystems (
      system: let
        pkgs = import nixpkgs {inherit system;};
      in
        pkgs.alejandra
    );
  };
}
