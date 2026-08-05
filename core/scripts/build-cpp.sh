#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_config

# A copied/synced project may contain a CMake cache created in a different
# absolute directory. CMake refuses to reuse it, so discard only the stale
# build tree and configure cleanly at the current project path.
cache_file="$PULSAR_BUILD_DIR/CMakeCache.txt"
if [[ -f "$cache_file" ]]; then
  cached_source="$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$cache_file" | head -n1)"
  if [[ -n "$cached_source" && "$cached_source" != "$PULSAR_ROOT" ]]; then
    warn "Removing stale CMake build cache from: $cached_source"
    rm -rf "$PULSAR_BUILD_DIR"
  fi
fi

mkdir -p "$PULSAR_BUILD_DIR"
cmake -S "$PULSAR_ROOT" -B "$PULSAR_BUILD_DIR" -DCMAKE_BUILD_TYPE=Release
cmake --build "$PULSAR_BUILD_DIR" --parallel "$(nproc)"
