{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    mirage-src = {
      url = "path:/home/marco/Github/mirage";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, mirage-src }: let
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

    mkFor = system: let
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      cudaPackages = pkgs.${cudaCfg.cudaPackagesAttr};
      gccHost = pkgs.${cudaCfg.gccHostAttr};

      # mirage-src is passed via --override-input from .envrc,
      # or defaults to the path: input above.
      src = mirage-src;

      mirage-rust-libs = pkgs.callPackage ./nix/mirage-rust-libs.nix {
        inherit (pkgs) lib rustPlatform;
        inherit src python3;
      };

      mirage-runtime = pkgs.callPackage ./nix/mirage-runtime.nix {
        inherit
          gccHost
          cudaPackages
          mirage-rust-libs
          src
          ;
        inherit (pkgs) autoAddDriverRunpath;
        inherit (cudaCfg) cudaArchitectures;
      };

      # Override Python so torch → torch-bin everywhere, avoiding conflicts.
      python3 = pkgs.python3.override {
        packageOverrides = _self: super: {
          torch = super.torch-bin;
        };
      };
      python3Packages = python3.pkgs;

      mirage-python = python3Packages.buildPythonPackage {
        pname = "mirage-project";
        version = "0.2.4";
        format = "setuptools";

        src = pkgs.lib.cleanSource mirage-src;

        # Disable the default build phases — we patch setup.py to skip
        # the Rust and CMake builds (they're pre-built).
        dontUseCmakeConfigure = true;

        nativeBuildInputs = [
          python3Packages.cython
          python3Packages.setuptools
          pkgs.autoAddDriverRunpath
          cudaPackages.cudatoolkit  # nvcc must be on PATH for setup.py CUDA detection
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
          python3Packages.torch  # resolves to torch-bin via override
          python3Packages.numpy
          python3Packages.z3-solver
          python3Packages.tqdm
          python3Packages.graphviz
          python3Packages.protobuf
          python3Packages.transformers
          python3Packages.accelerate
        ];

        postPatch = ''
          # Replace lines 145-232 of setup.py (Rust install + cargo builds + CMake build)
          # with minimal stubs. The pre-built libs are symlinked in preBuild.
          python3 << 'PATCH_EOF'
          with open('setup.py', 'r') as f:
              lines = f.readlines()

          # Lines 145-232 (0-indexed: 144-231) contain the Rust/CMake build logic.
          # Replace them with a minimal mirage_path assignment.
          stub = [
              "# (Nix: Rust libs and runtime are pre-built)\n",
              "mirage_path = path.dirname(__file__) or '.'\n",
              "\n",
          ]
          lines[144:232] = stub

          with open('setup.py', 'w') as f:
              f.writelines(lines)
          PATCH_EOF

          # Add lib/stubs to cuda_library_dirs for Nix CUDA layout
          substituteInPlace setup.py \
            --replace-fail \
              'os.path.join(cuda_home, "lib64", "stubs"),' \
              'os.path.join(cuda_home, "lib64", "stubs"), os.path.join(cuda_home, "lib", "stubs"),'

          # Patch __init__.py to use Nix store paths for .so preloading
          substituteInPlace python/mirage/__init__.py \
            --replace-fail \
              '_z3_so_path = os.path.join(_z3_libdir, "libz3.so")' \
              '_z3_so_path = "${pkgs.z3.lib}/lib/libz3.so"' \
            --replace-fail \
              '_subexpr_so_path = os.path.join(_mirage_root, "build", "abstract_subexpr", "release", "libabstract_subexpr.so")' \
              '_subexpr_so_path = "${mirage-rust-libs.abstract_subexpr}/lib/libabstract_subexpr.so"' \
            --replace-fail \
              '_formal_verifier_so_path = os.path.join(_mirage_root, "build", "formal_verifier", "release", "libformal_verifier.so")' \
              '_formal_verifier_so_path = "${mirage-rust-libs.formal_verifier}/lib/libformal_verifier.so"'
        '';

        preBuild = ''
          # Create the build directory structure that setup.py / config_cython() expects
          mkdir -p build/abstract_subexpr/release
          mkdir -p build/formal_verifier/release

          ln -sf ${mirage-runtime}/lib/libmirage_runtime.a build/ 2>/dev/null || true
          ln -sf ${mirage-runtime}/lib/libmirage_runtime.so build/ 2>/dev/null || true
          ln -sf ${mirage-rust-libs.abstract_subexpr}/lib/libabstract_subexpr.so build/abstract_subexpr/release/
          ln -sf ${mirage-rust-libs.formal_verifier}/lib/libformal_verifier.so build/formal_verifier/release/

          # Populate deps/ with include content from mirage-runtime
          # (submodules not available in flake source)
          mkdir -p deps/cutlass/include deps/cutlass/tools/util/include deps/json/include
          cp -r --no-preserve=mode ${mirage-runtime}/include/cutlass deps/cutlass/include/
          cp -r --no-preserve=mode ${mirage-runtime}/include/cute deps/cutlass/include/
          cp -r --no-preserve=mode ${mirage-runtime}/include/cutlass deps/cutlass/tools/util/include/ 2>/dev/null || true

          # nlohmann/json headers from nixpkgs
          cp -r --no-preserve=mode ${pkgs.nlohmann_json}/include/nlohmann deps/json/include/
        '';

        # Environment for the Cython extension compilation
        CUDA_HOME = "${cudaPackages.cudatoolkit}";
        CUDACXX = "${cudaPackages.cudatoolkit}/bin/nvcc";
        CC = "${gccHost}/bin/gcc";
        CXX = "${gccHost}/bin/g++";

        meta = {
          description = "Mirage: A Multi-Level Superoptimizer for Tensor Algebra";
          license = pkgs.lib.licenses.asl20;
          platforms = pkgs.lib.platforms.linux;
        };
      };

      # ----------------------------------------------------------------
      # DevShell
      # ----------------------------------------------------------------
      pyEnv = python3.withPackages (ps: [
        ps.cython
        ps.setuptools
        ps.wheel
        ps.z3-solver
        ps.torch  # resolves to torch-bin via override
        ps.numpy
        ps.transformers
        ps.accelerate
        ps.tqdm
        ps.graphviz
        ps.protobuf
        ps.pytest
      ]);
      # Python interpreter with mirage + all deps — use for testing/running
      mirageEnv = python3.withPackages (ps: [ mirage-python ps.pytest ]);
    in {
      packages = {
        mirage-rust-libs-abstract-subexpr = mirage-rust-libs.abstract_subexpr;
        mirage-rust-libs-formal-verifier = mirage-rust-libs.formal_verifier;
        mirage-runtime = mirage-runtime;
        mirage-python = mirage-python;
        "mirage-env" = mirageEnv;
        default = mirage-python;
      };

      devShells.default = pkgs.mkShell {
        packages = [
          # Build tools
          pkgs.cmake
          pkgs.gnumake
          gccHost
          pkgs.pkg-config
          pkgs.git
          pkgs.patchelf

          # CUDA
          cudaPackages.cudatoolkit
          cudaPackages.cuda_cudart

          # Rust
          pkgs.rustc
          pkgs.cargo

          # Z3
          pkgs.z3

          # Python environment
          pyEnv

          # autoAddDriverRunpath for any binaries built in the shell
          pkgs.autoAddDriverRunpath
        ];

        env = {
          CUDA_HOME = "${cudaPackages.cudatoolkit}";
          CUDACXX = "${cudaPackages.cudatoolkit}/bin/nvcc";
          CC = "${gccHost}/bin/gcc";
          CXX = "${gccHost}/bin/g++";
          Z3_LIBRARY_PATH = "${pkgs.z3.lib}/lib";
        };

        shellHook = ''
          echo "mirage devShell"
          echo "  CUDA:   $(nvcc --version 2>/dev/null | grep release | head -1)"
          echo "  GCC:    $(${gccHost}/bin/gcc --version | head -1)"
          echo "  Rust:   $(rustc --version)"
          echo "  Python: $(python3 --version)"
          export MIRAGE_HOME="$PWD"
        '';
      };
    };
  in {
    packages = forAllSystems (s: (mkFor s).packages);
    devShells = forAllSystems (s: (mkFor s).devShells);
    formatter = forAllSystems (
      system: let
        pkgs = import nixpkgs { inherit system; };
      in
        pkgs.alejandra
    );
  };
}
