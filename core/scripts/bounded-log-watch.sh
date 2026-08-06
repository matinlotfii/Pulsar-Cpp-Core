#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/common.sh"
load_config

watched_pid="${1:-}"
interval="${PULSAR_LOG_ROTATE_INTERVAL_SEC:-60}"
maximum_mb="${PULSAR_LOG_MAX_MB:-24}"
retain_mb="${PULSAR_LOG_RETAIN_MB:-6}"
maximum_bytes=$((maximum_mb * 1024 * 1024))
retain_bytes=$((retain_mb * 1024 * 1024))

[[ "$watched_pid" =~ ^[0-9]+$ ]] || exit 0

shrink_in_place() {
  local file="$1" size tmp
  [[ -f "$file" ]] || return 0
  size="$(stat -c '%s' "$file" 2>/dev/null || echo 0)"
  ((size > maximum_bytes)) || return 0
  tmp="${file}.bounded.$$"
  tail -c "$retain_bytes" "$file" >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

while kill -0 "$watched_pid" 2>/dev/null; do
  sleep "$interval"
  shrink_in_place "$PULSAR_LOG_FILE"
  shrink_in_place "$PULSAR_DATA_DIR/browser.log"
  shrink_in_place "$PULSAR_DATA_DIR/touch.log"
done
