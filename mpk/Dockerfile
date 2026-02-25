# Build mirage via Nix flake - produces a working non-editable package.
#
# Usage:
#   docker build -t mirage-nix -f mpk/Dockerfile .
#   docker run --rm --gpus all mirage-nix python -c "import mirage; print('ok')"
#
# The build runs entirely in the Nix sandbox (no GPU required).
# Runtime needs nvidia-container-toolkit for libcuda.so.

FROM nixos/nix:latest AS builder

# Enable flakes and accept the nixos-* cache
RUN mkdir -p /etc/nix && echo "\
experimental-features = nix-command flakes\n\
accept-flake-config = true\n\
" >> /etc/nix/nix.conf

COPY . /flake
WORKDIR /flake/mpk

# Build the mirage Python environment (interpreter + mirage + deps).
# The --override-input is not needed here because the flake.lock pins mirage-src.
RUN nix build .#mirage-env -o /result -L

# Run the packaging check to verify .so bundling
RUN nix build .#checks.x86_64-linux.packaging -L

# Minimal runtime image - just the Nix store closure
FROM nixos/nix:latest

RUN mkdir -p /etc/nix && echo "\
experimental-features = nix-command flakes\n\
" >> /etc/nix/nix.conf

COPY --from=builder /result /result
COPY --from=builder /nix/store /nix/store

# Smoke test (no GPU needed for find_spec check)
RUN /result/bin/python -c "\
import importlib.util; \
spec = importlib.util.find_spec('mirage'); \
assert spec is not None, 'mirage not found'; \
print(f'mirage installed at: {spec.submodule_search_locations[0]}'); \
"

ENTRYPOINT ["/result/bin/python"]
