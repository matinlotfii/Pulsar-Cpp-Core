#!/usr/bin/env bash
set -euo pipefail
PULSAR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PULSAR_BUILD_DIR="$PULSAR_ROOT/core/build"
PULSAR_BINARY="$PULSAR_BUILD_DIR/pulsar-core"
PULSAR_DATA_DIR="${PULSAR_DATA_ROOT:-$PULSAR_ROOT/core/data}"
PULSAR_LOG_FILE="$PULSAR_DATA_DIR/pulsar.log"
PULSAR_PID_FILE="$PULSAR_DATA_DIR/pulsar.pid"
PULSAR_GALAXY_LIB="$PULSAR_ROOT/camera/vendor/galaxy/lib"

load_config() {
  set -a
  # shellcheck disable=SC1091
  source "$PULSAR_ROOT/core/config/pulsar.env"
  if [[ -f "$PULSAR_ROOT/core/config/pulsar.local.env" ]]; then
    # shellcheck disable=SC1091
    source "$PULSAR_ROOT/core/config/pulsar.local.env"
  fi
  set +a
  export PULSAR_UI_ROOT="$PULSAR_ROOT/ui/dist"
  export PULSAR_DATA_ROOT="$PULSAR_DATA_DIR"
  export GENICAM_GENTL64_PATH="$PULSAR_GALAXY_LIB${GENICAM_GENTL64_PATH:+:$GENICAM_GENTL64_PATH}"
  export LD_LIBRARY_PATH="$PULSAR_GALAXY_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export GX_LOG_CONFIG="$PULSAR_ROOT/camera/vendor/galaxy/config/log4cplus.properties"
}

log() { printf '\033[1;36m[Pulsar]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[Pulsar]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[Pulsar]\033[0m %s\n' "$*" >&2; exit 1; }

find_browser() {
  local candidate
  for candidate in "${PULSAR_BROWSER:-}" google-chrome-stable google-chrome chromium chromium-browser; do
    [[ -n "$candidate" ]] || continue
    if command -v "$candidate" >/dev/null 2>&1; then command -v "$candidate"; return 0; fi
  done
  return 1
}

wait_for_core() {
  local url="http://${PULSAR_HOST:-127.0.0.1}:${PULSAR_PORT:-4173}/health"
  for _ in $(seq 1 80); do
    curl -fsS --max-time 1 "$url" >/dev/null 2>&1 && return 0
    sleep .1
  done
  return 1
}
