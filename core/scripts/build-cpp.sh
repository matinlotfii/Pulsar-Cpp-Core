#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
load_config

# SSH non-interactive shells do not always load ~/.profile. Use the versioned
# toolkit directly so remote builds are deterministic.
if [[ -x /usr/local/cuda-13.2/bin/nvcc ]]; then
  export CUDA_HOME="${CUDA_HOME:-/usr/local/cuda-13.2}"
  export CUDACXX="${CUDACXX:-$CUDA_HOME/bin/nvcc}"
  export PATH="$CUDA_HOME/bin:$PATH"
fi

require_cuda="${PULSAR_REQUIRE_CUDA:-0}"
if [[ "$require_cuda" == "1" && ( -z "${CUDACXX:-}" || ! -x "$CUDACXX" ) ]]; then
  die "CUDA Toolkit 13.2/NVCC was not found at /usr/local/cuda-13.2/bin/nvcc."
fi

cache_file="$PULSAR_BUILD_DIR/CMakeCache.txt"
if [[ -f "$cache_file" ]]; then
  cached_source="$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$cache_file" | head -n1)"
  cached_cuda="$(sed -n 's/^CMAKE_CUDA_COMPILER:[^=]*=//p' "$cache_file" | head -n1)"
  if [[ -n "$cached_source" && "$cached_source" != "$PULSAR_ROOT" ]]; then
    warn "Removing stale CMake cache created at: $cached_source"
    rm -rf "$PULSAR_BUILD_DIR"
  elif [[ "$require_cuda" == "1" && "$cached_cuda" != "$CUDACXX" ]]; then
    warn "Removing stale/non-CUDA CMake cache."
    rm -rf "$PULSAR_BUILD_DIR"
  fi
fi

mkdir -p "$PULSAR_BUILD_DIR"
cmake_args=(
  -S "$PULSAR_ROOT"
  -B "$PULSAR_BUILD_DIR"
  -DCMAKE_BUILD_TYPE=Release
)
if [[ -n "${CUDACXX:-}" && -x "$CUDACXX" ]]; then
  cmake_args+=(
    -DCMAKE_CUDA_COMPILER="$CUDACXX"
    -DCMAKE_CUDA_ARCHITECTURES=86
  )
fi
cmake "${cmake_args[@]}"

if [[ "$require_cuda" == "1" ]]; then
  cuda_compiler="$(sed -n 's/^CMAKE_CUDA_COMPILER:[^=]*=//p' "$PULSAR_BUILD_DIR/CMakeCache.txt" | head -n1)"
  if [[ -z "$cuda_compiler" || "$cuda_compiler" == "NOTFOUND" || ! -x "$cuda_compiler" ]]; then
    die "CMake did not configure the required CUDA compiler."
  fi
  if ! grep -q '^PULSAR_CUDA_AVAILABLE:BOOL=ON$' "$PULSAR_BUILD_DIR/CMakeCache.txt"; then
    die "CMake found NVCC but did not enable the CUDA/NPP camera pipeline."
  fi
  log "CUDA/NPP pipeline confirmed: $cuda_compiler"
fi

cmake --build "$PULSAR_BUILD_DIR" --parallel "$(nproc)"
