#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
load_config

LOCK_FILE="$PULSAR_DATA_DIR/display-hotplug.lock"
LAST_FILE="$PULSAR_DATA_DIR/display-hotplug.signature"
PID_FILE="$PULSAR_DATA_DIR/display-hotplug.pid"
INTERVAL="${PULSAR_DISPLAY_HOTPLUG_FALLBACK_INTERVAL:-5}"
DEBOUNCE="${PULSAR_DISPLAY_HOTPLUG_DEBOUNCE_SECONDS:-0.35}"
mkdir -p "$PULSAR_DATA_DIR"
echo "$$" >"$PID_FILE"

cleanup() {
  rm -f "$PID_FILE"
  [[ -n "${fallback_pid:-}" ]] && kill "$fallback_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

signature() {
  timeout 2 xrandr --query 2>/dev/null |
    awk '$2=="connected" || $2=="disconnected" {print $1 "|" $2 "|" $0}' |
    LC_ALL=C sort |
    sha256sum | awk '{print $1}'
}

apply_if_changed() {
  local current previous=""
  current="$(signature || true)"
  [[ -n "$current" ]] || return 0
  [[ -f "$LAST_FILE" ]] && previous="$(<"$LAST_FILE")"
  [[ "$current" != "$previous" ]] || return 0

  (
    flock -n 9 || exit 0
    sleep "$DEBOUNCE"
    current="$(signature || true)"
    [[ -n "$current" ]] || exit 0
    previous=""
    [[ -f "$LAST_FILE" ]] && previous="$(<"$LAST_FILE")"
    [[ "$current" != "$previous" ]] || exit 0

    start_ns="$(date +%s%N)"
    if nice -n 18 ionice -c3 \
      "$PULSAR_ROOT/core/scripts/configure-displays.sh" \
      >>"$PULSAR_LOG_FILE" 2>&1; then
      printf '%s' "$current" >"$LAST_FILE"
      end_ns="$(date +%s%N)"
      elapsed_ms=$(((end_ns-start_ns)/1000000))
      printf '%s\n' \
        "Pulsar display hotplug: independent RTX topology updated in ${elapsed_ms}ms; UI state file refreshed." \
        >>"$PULSAR_LOG_FILE"
    else
      printf '%s\n' \
        "Pulsar display hotplug: topology update failed; previous scanout remains active." \
        >>"$PULSAR_LOG_FILE"
    fi
  ) 9>"$LOCK_FILE"
}

# PULSAR_INITIAL_DISPLAY_REAPPLY_V1
# Apply the display topology once after Xorg, Chrome and NVIDIA-G0 are ready.
# Otherwise a late DP connector can become the watcher baseline without
# receiving a CRTC, mode or position.
if nice -n 18 ionice -c3 "$PULSAR_ROOT/core/scripts/configure-displays.sh" >>"$PULSAR_LOG_FILE" 2>&1; then
  printf '%s\n'     "Pulsar display hotplug: initial settled topology applied."     >>"$PULSAR_LOG_FILE"
fi

# PULSAR_WATCHER_INITIAL_REAPPLY_V1
# NVIDIA can expose DP after the first session configure pass. Reapply before
# recording the baseline so "connected but inactive" is never accepted.
if nice -n 18 ionice -c3 \
  "$PULSAR_ROOT/core/scripts/configure-displays.sh" \
  >>"$PULSAR_LOG_FILE" 2>&1; then
  printf '%s\n' \
    "Pulsar display hotplug: initial RTX topology reapplied before baseline." \
    >>"$PULSAR_LOG_FILE"
fi

initial="$(signature || true)"
[[ -n "$initial" ]] && printf '%s' "$initial" >"$LAST_FILE"

fallback_loop() {
  while true; do
    sleep "$INTERVAL"
    apply_if_changed || true
  done
}
fallback_loop &
fallback_pid=$!

if command -v udevadm >/dev/null 2>&1; then
  udevadm monitor --udev --subsystem-match=drm 2>/dev/null |
    while IFS= read -r line; do
      [[ "$line" == UDEV* ]] || continue
      apply_if_changed || true
    done
else
  wait "$fallback_pid"
fi
