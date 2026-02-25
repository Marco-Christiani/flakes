{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  gccHost,
  cudaPackages,
  autoAddDriverRunpath,
  z3,
  nlohmann_json,
  mirage-rust-libs,
  cudaArchitectures ? ["86"],
  src,
}: let
  cudaArchStr = lib.concatStringsSep ";" cudaArchitectures;

  cutlass-src = fetchFromGitHub {
    owner = "NVIDIA";
    repo = "cutlass";
    rev = "v4.2.1";
    hash = "sha256-iP560D5Vwuj6wX1otJhwbvqe/X4mYVeKTpK533Wr5gY=";
  };
in
  stdenv.mkDerivation {
    pname = "mirage-runtime";
    version = "0.2.4";

    inherit src;
    strictDeps = true;

    nativeBuildInputs = [cmake autoAddDriverRunpath];

    buildInputs = [
      cudaPackages.cudatoolkit
      cudaPackages.cuda_cudart
      z3
      nlohmann_json
      mirage-rust-libs.abstract_subexpr
      mirage-rust-libs.formal_verifier
    ];

    postPatch = ''
      # Populate deps/ with fetched submodule sources
      mkdir -p deps
      rm -rf deps/cutlass deps/json
      ln -s ${cutlass-src} deps/cutlass

      # Use CUDA stubs for libcuda.so at build time
      # (autoAddDriverRunpath handles the real driver at runtime)
      substituteInPlace cmake/cuda.cmake \
        --replace-fail \
          'set(CUDA_CUDA_LIBRARY ''${CUDAToolkit_LIBRARY_DIR}/libcuda.so)' \
          'set(CUDA_CUDA_LIBRARY ''${CUDAToolkit_LIBRARY_DIR}/stubs/libcuda.so)'

      # Rust libs are pre-built by Nix - skip version checks
      substituteInPlace CMakeLists.txt \
        --replace-fail \
          'execute_process(COMMAND rustc --version' \
          'execute_process(COMMAND true #' \
        --replace-fail \
          'execute_process(COMMAND cargo --version' \
          'execute_process(COMMAND true #'

      # Use nlohmann_json from nixpkgs instead of bundled submodule
      substituteInPlace CMakeLists.txt \
        --replace-fail \
          'add_subdirectory(deps/json)' \
          'find_package(nlohmann_json REQUIRED)'

      # Remove hardcoded Rust lib defaults so -D flags take effect
      substituteInPlace CMakeLists.txt \
        --replace-fail \
          'set(ABSTRACT_SUBEXPR_LIBRARIES ''${PROJECT_SOURCE_DIR}/build/abstract_subexpr/release/libabstract_subexpr.so)' \
          '# Rust libs provided via -D flags' \
        --replace-fail \
          'set(FORMAL_VERIFIER_LIBRARIES ''${PROJECT_SOURCE_DIR}/build/formal_verifier/release/libformal_verifier.so)' \
          '# Rust libs provided via -D flags'
    '';

    cmakeFlags = [
      "-DCMAKE_BUILD_TYPE=Release"
      "-DCMAKE_C_COMPILER=${gccHost}/bin/gcc"
      "-DCMAKE_CXX_COMPILER=${gccHost}/bin/g++"
      "-DCMAKE_CUDA_COMPILER=${cudaPackages.cudatoolkit}/bin/nvcc"
      "-DCMAKE_CUDA_HOST_COMPILER=${gccHost}/bin/g++"
      "-DCMAKE_CUDA_ARCHITECTURES=${cudaArchStr}"
      "-DZ3_CXX_INCLUDE_DIRS=${z3.dev}/include"
      "-DZ3_LIBRARIES=${z3.lib}/lib/libz3.so"
      "-DABSTRACT_SUBEXPR_LIB=${mirage-rust-libs.abstract_subexpr}/lib"
      "-DABSTRACT_SUBEXPR_LIBRARIES=${mirage-rust-libs.abstract_subexpr}/lib/libabstract_subexpr.so"
      "-DFORMAL_VERIFIER_LIB=${mirage-rust-libs.formal_verifier}/lib"
      "-DFORMAL_VERIFIER_LIBRARIES=${mirage-rust-libs.formal_verifier}/lib/libformal_verifier.so"
    ];

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib $out/include

      cp libmirage_runtime.a $out/lib/ 2>/dev/null || true
      cp libmirage_runtime.so $out/lib/ 2>/dev/null || true
      cp ${mirage-rust-libs.abstract_subexpr}/lib/libabstract_subexpr.so $out/lib/
      cp ${mirage-rust-libs.formal_verifier}/lib/libformal_verifier.so $out/lib/

      cp -r --no-preserve=mode,ownership $NIX_BUILD_TOP/$sourceRoot/include/. $out/include/
      cp -r --no-preserve=mode,ownership ${cutlass-src}/include/. $out/include/
      cp -r --no-preserve=mode,ownership ${cutlass-src}/tools/util/include/. $out/include/

      runHook postInstall
    '';

    meta = {
      description = "Mirage C++/CUDA runtime library";
      license = lib.licenses.asl20;
      platforms = lib.platforms.linux;
    };
  }
