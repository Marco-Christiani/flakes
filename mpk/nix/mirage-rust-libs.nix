{
  lib,
  rustPlatform,
  python3,
  src,
}: let
  mkRustLib = {
    pname,
    crateDir,
    cargoHash,
  }:
    rustPlatform.buildRustPackage {
      inherit pname;
      version = "0.1.0";

      # Extract only the crate subdirectory.
      src = "${src}/${crateDir}";

      inherit cargoHash;

      # pyo3 needs a Python interpreter at build time.
      nativeBuildInputs = [python3];

      # cdylib - install the .so to $out/lib.
      # buildRustPackage uses --target so output lands in target/<triple>/release/
      installPhase = ''
        runHook preInstall
        mkdir -p $out/lib
        find target -name 'lib${pname}.so' -type f -exec cp {} $out/lib/ \;
        runHook postInstall
      '';

      meta = {
        description = "Mirage Rust cdylib: ${pname}";
        license = lib.licenses.asl20;
        platforms = lib.platforms.linux;
      };
    };
in {
  abstract_subexpr = mkRustLib {
    pname = "abstract_subexpr";
    crateDir = "src/search/abstract_expr/abstract_subexpr";
    cargoHash = "sha256-NHmn/81I7Rccago8do9KYqIW3POPMijdI9OEPWde9xc=";
  };

  formal_verifier = mkRustLib {
    pname = "formal_verifier";
    crateDir = "src/search/verification/formal_verifier_equiv";
    cargoHash = "sha256-meKYroexmDTVRBjoiJP9KIfME1kaP+nU6GDzfUlHVKY=";
  };
}
