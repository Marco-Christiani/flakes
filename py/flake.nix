{
  description = "FHS shell for foreign Python + uv + host driver visibility";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
    ...
  }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {inherit system;};
    fhs = pkgs.buildFHSEnv {
      name = "python-fhs";

      targetPkgs = pkgs:
        with pkgs; [
          uv
          fish

          # needed for torch compile presumably jit cant remember if triton or torch, example missing file is crti.o
          glibc.dev

          # C compiler is needed, CC will be checked, verify with:
          # python -c "from triton.backends.nvidia import driver; print(driver.CudaUtils())"
          gcc

          # python312
          # bashInteractive

          # openssl
          # libffi
          # xz
          # bzip2
          # sqlite
          # ncurses
          # readline
          # expat
        ];

      runScript = "fish";
      profile = let
        runtimeLibs = pkgs.lib.makeLibraryPath (with pkgs; [
          stdenv.cc.cc # many pkgs need this visible, injected in LD_LIBRARY_PATH (fastest known test is jupyter rn)
          zlib # similar comment, (fastest known test is triton rn)
        ]);
      in ''
        # make libstdc++ visible
        export LD_LIBRARY_PATH="${pkgs.stdenv.cc.cc.lib}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        export LD_LIBRARY_PATH="${runtimeLibs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

        if [ -d /run/opengl-driver/lib ]; then
          export LD_LIBRARY_PATH="/run/opengl-driver/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        fi
      '';
    };
  in {
    # simplest approach, but nix develop -c <cmd> wont work (regardless of runScript being present or removed)
    devShells.${system}.default = fhs.env;
    # this is an attempt to allow -c <cmd> to work, but wont work due to the exec
    # devShells.${system}.default = pkgs.mkShell {
    #   packages = [fhs];
    #   shellHook = ''
    #     exec ${fhs}/bin/python-fhs
    #   '';
    # };
  };
}
