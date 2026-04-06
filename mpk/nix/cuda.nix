{
  # Central CUDA policy for mirage.
  # Keep all arch / toolkit / host-compiler choices here.

  # Dev default: RTX 3090.
  # Override by editing this policy file (or by passing `cudaArchitectures`
  # directly to nix/mirage-runtime.nix when calling it).
  cudaArchitectures = ["86"];

  # Optional full set for release / CI builds (use when wiring multi-arch builds).
  allArchitectures = ["75" "80" "86" "89" "90"];

  # Host compiler for nvcc.
  gccHostAttr = "gcc13";

  # CUDA toolkit version.
  cudaPackagesAttr = "cudaPackages_12";
}
