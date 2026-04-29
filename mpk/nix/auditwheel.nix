{
  lib,
  pkgs,
}: {
  name,
  wheelDir,
  wheelGlob ? "*.whl",
  extraSearchDirs ? [],
  plat ? "auto",
  libSdir ? ".libs",
  updateTags ? true,
  strip ? false,
  exclude ? [],
  onlyPlat ? false,
  disableIsaExtCheck ? false,
  zipCompressionLevel ? 6,
  python ? pkgs.python3,
  auditwheel ? pkgs.python3Packages.auditwheel,
}: let
  wheelDirEscaped = lib.escapeShellArg wheelDir;
  extraSearchDirsValue = lib.concatStringsSep ":" extraSearchDirs;
  extraSearchDirsEscaped = lib.escapeShellArg extraSearchDirsValue;
  repairArgs =
    [
      "--plat"
      (lib.escapeShellArg plat)
      "--lib-sdir"
      (lib.escapeShellArg libSdir)
      "-z"
      (toString zipCompressionLevel)
    ]
    ++ lib.optionals (!updateTags) ["--no-update-tags"]
    ++ lib.optionals strip ["--strip"]
    ++ lib.optionals onlyPlat ["--only-plat"]
    ++ lib.optionals disableIsaExtCheck ["--disable-isa-ext-check"]
    ++ lib.concatMap (pattern: ["--exclude" (lib.escapeShellArg pattern)]) exclude;
  repairArgsString = lib.concatStringsSep " " repairArgs;
  repairPython = python.withPackages (ps: [
    ps.auditwheel
    ps.pyelftools
  ]);
  repairPythonBin = "${repairPython}/bin/python";
  auditwheelBin = lib.getExe auditwheel;
  repairSupport = ./repair-wheel.py;

  selectWheelFromDir = dir: ''
    wheel_path=$(find ${dir} -maxdepth 1 -type f -name '${wheelGlob}' | sort | head -n1)
    if [ -z "$wheel_path" ]; then
      echo "No wheel matching pattern ${wheelGlob} found in ${dir}" >&2
      exit 1
    fi
  '';
in {
  inherit repairPython;

  repairWheelApp = pkgs.writeShellApplication {
    name = "${name}-repair-wheel";
    runtimeInputs = [
      auditwheel
      pkgs.binutils
      pkgs.nix
      pkgs.patchelf
      repairPython
    ];
    text = ''
      if [ $# -lt 2 ]; then
        echo "usage: ${name}-repair-wheel WHEEL_PATH OUT_DIR" >&2
        exit 2
      fi

      wheel_path=$1
      out_dir=$2

      mkdir -p "$out_dir"
      NIX_WHEEL_REPAIR_EXTRA_SEARCH_DIRS=${extraSearchDirsEscaped} \
        exec ${repairPythonBin} ${repairSupport} ${repairArgsString} "$wheel_path" "$out_dir"
    '';
  };

  repairedWheel = pkgs.stdenv.mkDerivation {
    pname = "${name}-wheel-repaired";
    version = "1";
    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    dontFixup = true;
    nativeBuildInputs = [
      auditwheel
      pkgs.binutils
      pkgs.nix
      pkgs.patchelf
      repairPython
    ];

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      ${selectWheelFromDir wheelDirEscaped}
      NIX_WHEEL_REPAIR_EXTRA_SEARCH_DIRS=${extraSearchDirsEscaped} \
        ${repairPythonBin} ${repairSupport} ${repairArgsString} "$wheel_path" "$out"
      runHook postInstall
    '';
  };

  showReport =
    pkgs.runCommand "${name}-auditwheel-show" {
      nativeBuildInputs = [auditwheel];
    } ''
      mkdir -p "$out"
      ${selectWheelFromDir wheelDirEscaped}
      ${auditwheelBin} show "$wheel_path" > "$out/report.txt"
    '';

  showApp = pkgs.writeShellApplication {
    name = "${name}-auditwheel-show";
    runtimeInputs = [auditwheel];
    text = ''
      if [ $# -gt 0 ]; then
        wheel_path=$1
      else
        ${selectWheelFromDir wheelDirEscaped}
      fi
      exec ${auditwheelBin} show "$wheel_path"
    '';
  };
}
