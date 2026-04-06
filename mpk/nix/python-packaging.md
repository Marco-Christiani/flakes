# Python Packaging Policy (MPK)

This document explains how Python dependencies are packaged in this flake, with
a focus on torch CUDA wheels on NixOS since this brings in complexity.

Fundamentally, what we want to:

- Preserve artifact-lineage parity with `uv.lock` / `uv sync`.
- Avoid PyTorch source builds, this is easy to trigger on accident, is
  prohibitively expensive, and can lock up the kernel completely.
- Keep NixOS compatibility deviations explicit and isolated, some deviation
  is required and unavoidable.

## Layering Model

The implementation in `nix/python-layer.nix` is intentionally split into three
layers:

1. Lock parity layer
   - `workspace.mkPyprojectOverlay { sourcePreference = "wheel"; }`
   - Source of truth is `uv.lock` package versions and wheel artifacts.

2. NixOS CUDA wheel compatibility layer
   - Adds ELF patching hooks and runpath behavior required on NixOS.
   - Adds explicit multi-node runtime libraries (RDMA/UCX/MPI stack).
   - Handles CUDA dependencies spread across multiple wheel packages.

3. Project-native layer
   - Injects Mirage native artifacts only into `mirage-project` build.

## Cross-wheel CUDA DSOs

Some CUDA `.so` files required by one wheel are physically shipped by another
wheel. Example: `nvidia-cusolver-cu12` libraries link to `libcublas.so.12`,
which is shipped in `nvidia-cublas-cu12`.

Because Nix patches each wheel derivation independently, these links are not
always available at patch time unless we explicitly expose sibling wheel libs.

## Explicit Deviations (and why)

- Driver libs (for example `libcuda.so.1`) are provided by the host NVIDIA
  driver, not by wheel artifacts.
- Cross-wheel CUDA DSOs are allowed in build-time missing-dep handling because
  they resolve in the final assembled environment that includes all wheel
  packages.
- Multi-node stack libraries (`rdma-core`, `ucx`, `libfabric`, `openmpi`,
  `pmix`) are added explicitly to support distributed/fabric plugins.

These deviations are grouped in `nix/python-layer.nix`.

## Validation Checks

Several flake checks:

- `checks.lock-parity`: verifies key package versions match `uv.lock`.
- `checks.torch-runtime-metadata`: verifies torch CUDA metadata and expected
  wheel-provided CUDA artifact layout.
- `checks.packaging`: existing packaging test suite.
