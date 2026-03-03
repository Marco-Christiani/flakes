{
  nixConfig = {
    extra-substituters = [
      "https://cuda-maintainers.cachix.org"
      "https://nix-community.cachix.org"
    ];
    extra-trusted-public-keys = [
      "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    mirage-src = {
      url = "path:/home/marco/Github/mirage";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    mirage-src,
  }: let
    systems = ["x86_64-linux"];

    forAllSystems = f:
      builtins.listToAttrs (
        map (system: {
          name = system;
          value = f system;
        })
        systems
      );

    cudaCfg = import ./nix/cuda.nix;

    # "Release" or "Debug" — applies to mirage-runtime CUDA/C++ build
    buildType = "Release";

    mkFor = system: let
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      inherit (pkgs) lib;

      cudaPackages = pkgs.${cudaCfg.cudaPackagesAttr};
      gccHost = pkgs.${cudaCfg.gccHostAttr};

      # torch-bin override: prevent accelerate/transformers pulling in
      # source-built torch which conflicts with the binary package.
      python3 = pkgs.python3.override {
        packageOverrides = _self: super: {
          torch = super.torch-bin;
        };
      };
      python3Packages = python3.pkgs;

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
        # Include parent dirs so the nested crate paths exist in the output.
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

      pythonSrc = mkSrc "mirage-python-src" (path: _type: let
        rp = relPath path;
      in
        builtins.elem (topDir path) ["python" "tests" "include"]
        || builtins.elem rp ["setup.py" "pyproject.toml" "MANIFEST.in" "config.cmake" "requirements.txt"]);

      # -- Derivations -----------------------------------------------------

      mirage-rust-libs = pkgs.callPackage ./nix/mirage-rust-libs.nix {
        src = rustSrc;
        inherit python3;
      };

      mirage-runtime = pkgs.callPackage ./nix/mirage-runtime.nix {
        inherit gccHost cudaPackages mirage-rust-libs buildType;
        src = runtimeSrc;
        inherit (cudaCfg) cudaArchitectures;
      };

      mirage-python = python3Packages.buildPythonPackage {
        pname = "mirage-project";
        version = "0.2.4";
        format = "setuptools";

        src = pythonSrc;

        dontUseCmakeConfigure = true;

        # setup.py has MIRAGE_SKIP_NATIVE_BUILD guard - skip cargo/cmake.
        MIRAGE_SKIP_NATIVE_BUILD = "1";

        nativeBuildInputs = [
          python3Packages.cython
          python3Packages.setuptools
          pkgs.autoAddDriverRunpath
          cudaPackages.cudatoolkit # nvcc on PATH for setup.py CUDA detection
        ];

        buildInputs = [
          mirage-runtime
          mirage-rust-libs.abstract_subexpr
          mirage-rust-libs.formal_verifier
          pkgs.z3
          cudaPackages.cudatoolkit
          cudaPackages.cuda_cudart
          gccHost
        ];

        propagatedBuildInputs = [
          python3Packages.torch
          python3Packages.numpy
          python3Packages.z3-solver
          python3Packages.tqdm
          python3Packages.graphviz
          python3Packages.protobuf
          python3Packages.transformers
          python3Packages.accelerate
        ];

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

        CUDA_HOME = "${cudaPackages.cudatoolkit}";
        CUDACXX = "${cudaPackages.cudatoolkit}/bin/nvcc";
        CC = "${gccHost}/bin/gcc";
        CXX = "${gccHost}/bin/g++";

        meta = {
          description = "Mirage: A Multi-Level Superoptimizer for Tensor Algebra";
          license = lib.licenses.asl20;
          platforms = lib.platforms.linux;
        };
      };

      # -- Environments & helpers ------------------------------------------

      # Python interpreter with mirage installed (for checks and app target)
      mirageEnv = python3.withPackages (ps: [mirage-python ps.pytest]);

      # Python interpreter for the devShell (editable workflow, no mirage)
      pyEnv = python3.withPackages (ps: [
        ps.pip
        ps.cython
        ps.setuptools
        ps.wheel
        ps.z3-solver
        ps.torch
        ps.numpy
        ps.transformers
        ps.accelerate
        ps.tqdm
        ps.graphviz
        ps.protobuf
        ps.pytest
      ]);

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
        exec ${mirageEnv}/bin/python -m pytest "$@"
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
    in {
      packages = {
        mirage-rust-libs-abstract-subexpr = mirage-rust-libs.abstract_subexpr;
        mirage-rust-libs-formal-verifier = mirage-rust-libs.formal_verifier;
        inherit mirage-runtime mirage-python;
        mirage-env = mirageEnv;
        default = mirage-python;
      };

      checks.packaging =
        pkgs.runCommand "mirage-packaging-test" {
          nativeBuildInputs = [mirageEnv];
        } ''
          set -o pipefail

          # No GPU driver in sandbox - use CUDA stubs for libcuda.so
          export LD_LIBRARY_PATH="${cudaPackages.cudatoolkit}/lib/stubs"

          python -m pytest -m "not impure" -p no:cacheprovider -v \
            ${pythonSrc}/tests/python/test_packaging.py 2>&1 | tee $out
        '';

      apps.test = {
        type = "app";
        program = "${mirage-test}/bin/mirage-test";
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
          pkgs.z3
          pyEnv
          pkgs.autoAddDriverRunpath

          # dev tools
          pkgs.pyright
          pkgs.ruff
          pkgs.ty # TODO: ty
          pkgs.mypy
          pkgs.act

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
          Z3_LIBRARY_PATH = "${pkgs.z3.lib}/lib";
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
    packages = forAllSystems (s: (mkFor s).packages);
    checks = forAllSystems (s: (mkFor s).checks);
    apps = forAllSystems (s: (mkFor s).apps);
    devShells = forAllSystems (s: (mkFor s).devShells);
    formatter = forAllSystems (
      system: let
        pkgs = import nixpkgs {inherit system;};
      in
        pkgs.alejandra
    );
  };
}
