{
  # Central CUDA policy for mirage.
  # Keep all arch / toolkit / host-compiler choices here.

  # Dev default: RTX 3090. Override via `--override-input` or `cudaArchitectures` arg.
  cudaArchitectures = ["86"];

  # Full set for release / CI builds.
  allArchitectures = ["75" "80" "86" "89" "90"];

  # Host compiler for nvcc.
  gccHostAttr = "gcc13";

  # CUDA toolkit version.
  cudaPackagesAttr = "cudaPackages_12";
}
