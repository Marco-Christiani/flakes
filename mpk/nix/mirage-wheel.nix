{
  lib,
  pkgs,
  python3,
  miragePython,
  mirageRuntime,
  mirageRustLibs,
  mirageZ3,
  cudaPackages,
}: let
  rawWheel = pkgs.stdenvNoCC.mkDerivation {
    pname = "mirage-python-wheel";
    inherit (miragePython) version;
    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    dontFixup = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -r ${miragePython.dist}/. "$out"/
      runHook postInstall
    '';

    meta = {
      description = "Raw Nix-built wheel artifact for mirage-project";
      platforms = lib.platforms.linux;
    };
  };

  auditwheelTools = import ./auditwheel.nix {inherit lib pkgs;} {
    name = "mirage";
    # Feed the original dist output into repair so the helper can recover the
    # wheel's build provenance from the producing derivation. rawWheel is a
    # presentation wrapper around that output, not the provenance source.
    wheelDir = miragePython.dist;
    # Search roots are explicit because Mirage's native pieces come from
    # sibling derivations rather than from one self-contained extension build.
    extraSearchDirs = [
      "${mirageRuntime}/lib"
      "${mirageRustLibs.abstract_subexpr}/lib"
      "${mirageRustLibs.formal_verifier}/lib"
      "${mirageZ3}/${python3.sitePackages}/z3/lib"
      "${cudaPackages.cuda_cudart}/lib"
    ];
    python = python3;
  };
in {
  inherit rawWheel auditwheelTools;
}
