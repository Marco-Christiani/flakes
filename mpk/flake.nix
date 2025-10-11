{
  description = "MPK Env";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        cudaPackages = pkgs.cudaPackages;

        commonBuildInputs = with pkgs; [
          cmake
          gnumake
          pkg-config
          git
          gcc13
          which
          patchelf

          # Verify
          rustc
          cargo
          z3

          # CUDA
          cudaPackages.cudatoolkit
          cudaPackages.cudnn
          cudaPackages.cuda_cudart
          (cudaPackages.libcutensor or cudaPackages.cutensor)

          # zigrad
          openblas
        ];

        libraryPath = pkgs.lib.makeLibraryPath [
          cudaPackages.cudatoolkit
          "${cudaPackages.cudatoolkit}/lib/stubs"  # libcuda.so stub
          cudaPackages.cuda_cudart
          cudaPackages.cudnn
          (cudaPackages.libcutensor or cudaPackages.cutensor)
          pkgs.z3
        ];

        commonShellHook = ''
          export CUDA_HOME="${cudaPackages.cudatoolkit}"
          export CUDA_PATH="${cudaPackages.cudatoolkit}"
          export CUDACXX="${cudaPackages.cudatoolkit}/bin/nvcc"
          export CUDA_INCLUDE_DIRS="${cudaPackages.cudatoolkit}/include"

          # Runtime library path
          export LD_LIBRARY_PATH="${cudaPackages.cudatoolkit}/lib:${cudaPackages.cudnn}/lib:${cudaPackages.cuda_cudart}/lib:$LD_LIBRARY_PATH"


          export Z3_LIBRARY_PATH="${pkgs.z3.lib}/lib"
          export LD_LIBRARY_PATH="${pkgs.z3.lib}/lib:${pkgs.gcc13}/lib:$LD_LIBRARY_PATH"

          export CC="${pkgs.gcc13}/bin/gcc"
          export CXX="${pkgs.gcc13}/bin/g++"

          export MIRAGE_HOME="$PWD"
          export MIRAGE_ROOT="$MIRAGE_HOME"
          export CMAKE_INSTALL_PREFIX="$PWD/install"

          echo "Mirage development environment loaded"
          echo "CUDA: ${cudaPackages.cudatoolkit.version}"
          echo "CMake: $(cmake --version | head -n1)"
          echo "Rust: $(rustc --version)"
          echo "GCC: $(gcc --version | head -n1)"
        '';

        pythonEnv = pkgs.python311.withPackages (ps: with ps; [
          pip
          setuptools
          wheel
          cython
          numpy
          # z3-solver
        ]);

      in
      {
        devShells = {
          cpp = pkgs.mkShell {
            packages = commonBuildInputs;

            CUDAToolkit_ROOT = "${cudaPackages.cudatoolkit}";
            CMAKE_PREFIX_PATH = pkgs.lib.makeSearchPath "" [
              cudaPackages.cudnn
              (cudaPackages.libcutensor or cudaPackages.cutensor)
              cudaPackages.cuda_cudart
            ];
            LIBRARY_PATH = libraryPath;

            shellHook = commonShellHook;
          };

          default = pkgs.mkShell {
            packages = commonBuildInputs ++ [ pythonEnv pkgs.stdenv.cc.cc.lib ];

            CUDAToolkit_ROOT = "${cudaPackages.cudatoolkit}";
            CMAKE_PREFIX_PATH = pkgs.lib.makeSearchPath "" [
              cudaPackages.cudnn
              (cudaPackages.libcutensor or cudaPackages.cutensor)
              cudaPackages.cuda_cudart
            ];
            LIBRARY_PATH = libraryPath;
            CUDACXX          = "${cudaPackages.cudatoolkit}/bin/nvcc";
            CC  = "${pkgs.gcc13.cc}/bin/gcc";
            CXX = "${pkgs.gcc13.cc}/bin/g++";

          shellHook = commonShellHook + ''
            if [ ! -d .venv ]; then
              echo "Creating Python venv..."
              python -m venv .venv
            fi
            source .venv/bin/activate

            # Install z3-solver first to get compatible libz3.so
            # we also need to deduce the path, so we do this ahead
            # of time
            pip install z3-solver

            # Get z3 paths from pip install
            export Z3_PYTHON_INCLUDE=$(python - <<'PY'
            import z3, os.path as p
            print(p.join(p.dirname(z3.__file__), "include"))
            PY
            )
            export Z3_PYTHON_LIB=$(python - <<'PY'
            import z3, glob, os.path as p
            d = p.join(p.dirname(z3.__file__), "lib")
            print(glob.glob(p.join(d, "libz3.so"))[0])
            PY
            )

            echo "Using pip's z3:"
            echo "  Include: $Z3_PYTHON_INCLUDE"
            echo "  Library: $Z3_PYTHON_LIB"
            export LD_LIBRARY_PATH="$(dirname $Z3_PYTHON_LIB):$LD_LIBRARY_PATH"

            echo "Patching mirage's cmake..."
            sed -i 's|''${CUDAToolkit_LIBRARY_DIR}/libcuda.so|''${CUDAToolkit_LIBRARY_DIR}/stubs/libcuda.so|' cmake/cuda.cmake

            # pip install -e . -v

            # can build like
            # cd build
            # cmake .. \
            #   -DBUILD_CPP_EXAMPLES=ON \
            #   -DZ3_CXX_INCLUDE_DIRS="$Z3_PYTHON_INCLUDE" \
            #   -DZ3_LIBRARIES="$Z3_PYTHON_LIB"
            # make -j$(nproc)

            echo "Python: $(python --version)"
            echo ""
            echo "Full DevShell (C++ + Python)"
            echo ""
            echo "CUDAToolkit_ROOT=$CUDAToolkit_ROOT"
            echo "CMAKE_PREFIX_PATH=$CMAKE_PREFIX_PATH"
            export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ]}:$LD_LIBRARY_PATH
          '';
          };

          minimal = pkgs.mkShell {
            packages = with pkgs; [
              cmake
              gnumake
              gcc13
              rustc
              cargo
              # z3
            ];

            shellHook = ''
              export CC="${pkgs.gcc13}/bin/gcc"
              export CXX="${pkgs.gcc13}/bin/g++"
            '';
          };
        };
      }
    );
}
