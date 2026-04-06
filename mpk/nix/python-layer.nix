/*
Python packaging policy for MPK

1) Artifact-lineage parity
   - Python dependency resolution comes from uv.lock wheels.
   - We do not replace torch/triton/nvidia-* with nixpkgs Python packages,
      generally we replacements at all costs for parity.

2) NixOS compatibility layer as explicit and isolated
   - We patch ELF/runpaths so Linux wheels work under Nix store semantics.
   - We add explicit runtime inputs for distributed fabrics (RDMA/UCX/MPI).

3) Project-native injection
   - We inject prebuilt Mirage native artifacts only into mirage-project.
*/
{
  # nixpkgs package set for target system
  pkgs,
  lib,
  # pyproject tooling inputs
  pyproject-nix,
  pyproject-build-systems,
  workspace,
  # project-specific native artifacts injected into mirage-project build
  mirage-runtime,
  mirage-rust-libs,
  cudaPackages,
  gccHost,
}: let
  inherit (pkgs) python3;

  # Base pyproject.nix package set.
  pythonBase = pkgs.callPackage pyproject-nix.build.packages {
    python = python3;
  };

  # Dependency lineage parity:
  # all Python dependencies come from uv.lock wheel resolution.
  lockParityOverlay = workspace.mkPyprojectOverlay {sourcePreference = "wheel";};

  # NixOS CUDA wheel compatibility:
  # Keep this as an isolated layer so deviations from plain uv/pip installs are
  # explicit and auditable.

  nvidiaCudaWheelPackages = [
    "nvidia-cublas-cu12"
    "nvidia-cuda-cupti-cu12"
    "nvidia-cuda-nvrtc-cu12"
    "nvidia-cuda-runtime-cu12"
    "nvidia-cudnn-cu12"
    "nvidia-cufile-cu12"
    "nvidia-cufft-cu12"
    "nvidia-curand-cu12"
    "nvidia-cusolver-cu12"
    "nvidia-cusparse-cu12"
    "nvidia-cusparselt-cu12"
    "nvidia-nccl-cu12"
    "nvidia-nvjitlink-cu12"
    "nvidia-nvshmem-cu12"
    "nvidia-nvtx-cu12"
  ];

  cudaConsumerPackages = [
    "torch"
    "triton"
  ];

  cudaWheelPackages = nvidiaCudaWheelPackages ++ cudaConsumerPackages;

  # Host driver provided libraries (outside Nix store).
  driverProvidedLibs = [
    "libcuda.so.1"
    "libnvidia-ml.so.1"
  ];

  # Multi-node communication stack used by CUDA wheel plugins (RDMA/UCX/MPI).
  # This is an explicit NixOS compatibility deviation from pure wheel installs,
  # intentionally grouped so it is easy to audit and discuss.
  multiNodeRuntimeInputs = [
    pkgs.rdma-core
    pkgs.ucx
    pkgs.libfabric
    pkgs.openmpi
    pkgs.pmix
  ];

  # CUDA DSOs intentionally split across NVIDIA PyPI wheels.
  #
  # Why keep these in ignoreMissing:
  # - autoPatchelf runs per wheel derivation
  # - many CUDA dependencies are provided by sibling wheels
  # - final virtualenv contains the full set and resolves them at runtime
  #
  # Example:
  # - nvidia-cusolver-cu12 may need libcublas.so.12 from nvidia-cublas-cu12.
  crossWheelCudaLibs = [
    "libcublas.so.*"
    "libcublasLt.so.*"
    "libcudart.so.*"
    "libcudnn*.so*"
    "libcufft.so.*"
    "libcufile.so.*"
    "libcurand.so.*"
    "libcusolver.so.*"
    "libcusparse.so.*"
    "libcusparseLt.so.*"
    "libcupti.so.*"
    "libnccl.so.*"
    "libnvJitLink.so.*"
    "libnvrtc.so.*"
    "libnvrtc-builtins.so.*"
    "libnvToolsExt.so.*"
    "libnvshmem*.so*"
  ];

  # Build-time ignore categories:
  # - driverProvidedLibs: expected from host driver, not in Nix store output
  # - crossWheelCudaLibs: provided by sibling CUDA wheels at final env runtime
  wheelCompatIgnore = driverProvidedLibs ++ crossWheelCudaLibs;

  mkCudaWheelCompatOverride = final: prev: name: let
    isCudaConsumer = builtins.elem name cudaConsumerPackages;

    nvidiaDeps = map (n: final.${n}) nvidiaCudaWheelPackages;

    nvidiaSearchPathsScript = lib.optionalString isCudaConsumer (
      lib.concatMapStringsSep "\n" (
        n: ''
          if [ -d "${final.${n}}/${python3.sitePackages}/nvidia" ]; then
            for libdir in "${final.${n}}/${python3.sitePackages}/nvidia"/*/lib; do
              if [ -d "$libdir" ]; then
                addAutoPatchelfSearchPath "$libdir"
              fi
            done
          fi
        ''
      )
      nvidiaCudaWheelPackages
    );
  in
    prev.${name}.overrideAttrs (old: {
      nativeBuildInputs =
        (old.nativeBuildInputs or [])
        ++ [
          pkgs.addDriverRunpath
          pkgs.autoAddDriverRunpath
          pkgs.autoPatchelfHook
        ];

      buildInputs =
        (old.buildInputs or [])
        ++ multiNodeRuntimeInputs
        ++ lib.optionals isCudaConsumer nvidiaDeps;

      # Keep this scoped and explicit. We intentionally avoid blanket "*".
      autoPatchelfIgnoreMissingDeps =
        lib.unique ((old.autoPatchelfIgnoreMissingDeps or []) ++ wheelCompatIgnore);

      postFixup =
        (old.postFixup or "")
        + nvidiaSearchPathsScript
        + ''
          if [ -d "$out/${python3.sitePackages}/nvidia" ]; then
            for libdir in "$out/${python3.sitePackages}/nvidia"/*/lib; do
                if [ -d "$libdir" ]; then
                  addAutoPatchelfSearchPath "$libdir"
                fi
            done
          fi
        ''
        + lib.optionalString (name == "torch") ''
          if [ -d "$out/${python3.sitePackages}/torch/lib" ]; then
            addAutoPatchelfSearchPath "$out/${python3.sitePackages}/torch/lib"
          fi
        '';
    });

  cudaWheelCompatOverlay = final: prev:
    builtins.listToAttrs (map (name: lib.nameValuePair name (mkCudaWheelCompatOverride final prev name)) cudaWheelPackages);

  # Project-native overrides.
  mirageNativeOverlay = final: prev: {
    # tg4perfetto uses hatchling but doesn't declare it in build-system.requires.
    # hatchling's own runtime deps (packaging, pathspec, pluggy,
    # trove-classifiers) must also be present since uv builds without
    # build isolation.
    tg4perfetto = prev.tg4perfetto.overrideAttrs (old: {
      nativeBuildInputs =
        (old.nativeBuildInputs or [])
        ++ [
          final.hatchling
          final.packaging
          final.pathspec
          final.pluggy
          final.trove-classifiers
        ];
    });

    # Inject pre-built native artifacts into the mirage-project build.
    mirage-project = prev.mirage-project.overrideAttrs (old: {
      nativeBuildInputs =
        (old.nativeBuildInputs or [])
        ++ [
          final.cython
          pkgs.autoAddDriverRunpath
          cudaPackages.cudatoolkit
        ];

      buildInputs =
        (old.buildInputs or [])
        ++ [
          mirage-runtime
          mirage-rust-libs.abstract_subexpr
          mirage-rust-libs.formal_verifier
          pkgs.z3
          cudaPackages.cudatoolkit
          cudaPackages.cuda_cudart
          gccHost
        ];

      env = {
        MIRAGE_SKIP_NATIVE_BUILD = "1";
        CUDA_HOME = "${cudaPackages.cudatoolkit}";
        CUDACXX = "${cudaPackages.cudatoolkit}/bin/nvcc";
        CC = "${gccHost}/bin/gcc";
        CXX = "${gccHost}/bin/g++";
      };

      preBuild = ''
        # Stage pre-built native libs where setup.py / config_cython() expects them
        mkdir -p build/abstract_subexpr/release build/formal_verifier/release
        ln -sf ${mirage-runtime}/lib/libmirage_runtime.a build/ 2>/dev/null || true
        ln -sf ${mirage-runtime}/lib/libmirage_runtime.so build/ 2>/dev/null || true
        ln -sf ${mirage-rust-libs.abstract_subexpr}/lib/libabstract_subexpr.so build/abstract_subexpr/release/
        ln -sf ${mirage-rust-libs.formal_verifier}/lib/libformal_verifier.so build/formal_verifier/release/

        # Provide submodule headers from mirage-runtime and nixpkgs
        mkdir -p deps/cutlass/include deps/cutlass/tools/util/include deps/json/include
        cp -r --no-preserve=mode ${mirage-runtime}/include/cutlass deps/cutlass/include/
        cp -r --no-preserve=mode ${mirage-runtime}/include/cute deps/cutlass/include/
        cp -r --no-preserve=mode ${mirage-runtime}/include/cutlass deps/cutlass/tools/util/include/ 2>/dev/null || true
        cp -r --no-preserve=mode ${pkgs.nlohmann_json}/include/nlohmann deps/json/include/
      '';
    });
  };

  pythonSet = pythonBase.overrideScope (
    lib.composeManyExtensions [
      pyproject-build-systems.overlays.default
      lockParityOverlay
      cudaWheelCompatOverlay
      mirageNativeOverlay
    ]
  );

  mirageEnv = pythonSet.mkVirtualEnv "mirage-env" workspace.deps.default;

  mirageDevEnv = pythonSet.mkVirtualEnv "mirage-env" {
    mirage-project = ["dev"];
  };
in {
  inherit
    python3
    pythonSet
    mirageEnv
    mirageDevEnv
    ;
}
