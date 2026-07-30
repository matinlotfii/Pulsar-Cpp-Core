#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_config
mkdir -p "$PULSAR_BUILD_DIR"
cmake -S "$PULSAR_ROOT" -B "$PULSAR_BUILD_DIR" -DCMAKE_BUILD_TYPE=Release
cmake --build "$PULSAR_BUILD_DIR" --parallel "$(nproc)"
