#!/usr/bin/env bash
set -euo pipefail

# PULSAR_CUDA_PATH_BOOTSTRAP
# Remote/non-interactive SSH shells may not load ~/.profile.
if [[ -x /usr/local/cuda-13.2/bin/nvcc ]]; then
  export CUDA_HOME="${CUDA_HOME:-/usr/local/cuda-13.2}"
  export CUDACXX="${CUDACXX:-$CUDA_HOME/bin/nvcc}"
  export PATH="$CUDA_HOME/bin:$PATH"
fi

source "$(dirname "$0")/common.sh"
load_config
mkdir -p "$PULSAR_BUILD_DIR"
cmake -S "$PULSAR_ROOT" -B "$PULSAR_BUILD_DIR" -DCMAKE_BUILD_TYPE=Release

if [[ "${PULSAR_REQUIRE_CUDA:-0}" == "1" ]]; then
  cuda_compiler="$(sed -n 's/^CMAKE_CUDA_COMPILER:[^=]*=//p' "$PULSAR_BUILD_DIR/CMakeCache.txt" | head -n 1)"
  if [[ -z "$cuda_compiler" || "$cuda_compiler" == "NOTFOUND" || ! -x "$cuda_compiler" ]]; then
    die "CUDA Toolkit/NVCC was not found. Install cuda-toolkit-13-2, or use RUN_REQUIRE_CUDA=0 only for a higher-latency CPU fallback."
  fi
fi

cmake --build "$PULSAR_BUILD_DIR" --parallel "$(nproc)"
