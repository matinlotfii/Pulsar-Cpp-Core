#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_config
mkdir -p "$PULSAR_DATA_DIR"
browser_pid=""
core_pid=""
openbox_pid=""
unclutter_pid=""
display_watch_pid=""
touch_log_file="$PULSAR_DATA_DIR/touch.log"

cleanup() {
  kill "$display_watch_pid" "$browser_pid" "$core_pid" "$openbox_pid" "$unclutter_pid" 2>/dev/null || true
  rm -f "$PULSAR_PID_FILE"
}
trap cleanup EXIT INT TERM

display_topology_signature() {
  # XRandR is the source of truth for this mixed Intel + NVIDIA GPU-screen
  # session. NVIDIA's DRM sysfs connector status can remain "disconnected"
  # even while HDMI-1-0 is connected and active through XRandR.
  xrandr --query 2>/dev/null |
    awk '$2 == "connected" { print }' |
    sort |
    sha256sum |
    awk '{print $1}'
}

watch_display_topology() {
  local watched_core_pid="$1"
  local interval="${PULSAR_DISPLAY_HOTPLUG_INTERVAL:-2}"
  local debounce_samples="${PULSAR_DISPLAY_HOTPLUG_DEBOUNCE_SAMPLES:-3}"
  local baseline candidate current candidate_samples=0

  baseline="$(display_topology_signature)"
  candidate="$baseline"

  while kill -0 "$watched_core_pid" 2>/dev/null; do
    sleep "$interval"
    current="$(display_topology_signature)"
    if [[ "$current" == "$baseline" ]]; then
      candidate="$baseline"
      candidate_samples=0
      continue
    fi

    if [[ "$current" == "$candidate" ]]; then
      candidate_samples=$((candidate_samples + 1))
    else
      candidate="$current"
      candidate_samples=1
    fi

    if ((candidate_samples >= debounce_samples)); then
      printf '%s\n' \
        "Pulsar display hotplug: stable topology change detected; restarting the kiosk for dynamic reconfiguration." \
        >>"$PULSAR_LOG_FILE"
      kill -TERM "$watched_core_pid" 2>/dev/null || true
      return 0
    fi
  done
}

"$PULSAR_ROOT/core/scripts/configure-displays.sh"
set -a
# shellcheck disable=SC1090
source "$PULSAR_DATA_DIR/displays.env"
set +a

# Start the window manager before native/browser windows so placement and
# fullscreen state are deterministic on Ubuntu Server Xorg sessions.
xset s off >/dev/null 2>&1 || true
xset -dpms >/dev/null 2>&1 || true
xset s noblank >/dev/null 2>&1 || true
openbox >/dev/null 2>&1 &
openbox_pid=$!
sleep .4
: >"$touch_log_file"
"$PULSAR_ROOT/core/scripts/configure-touch.sh" --watch --attempts 120 --interval 2 >>"$touch_log_file" 2>&1 &

if [[ -f "$PULSAR_PID_FILE" ]] && kill -0 "$(cat "$PULSAR_PID_FILE")" 2>/dev/null; then
  kill "$(cat "$PULSAR_PID_FILE")" || true
  sleep .4
fi

core_command=(
  "$PULSAR_BINARY"
  --ui-root "$PULSAR_ROOT/ui/dist"
  --data-root "$PULSAR_DATA_DIR"
)

if [[ "${PULSAR_CORE_NVIDIA_OFFLOAD:-0}" == "1" ]]; then
  core_command=(
    env
    __NV_PRIME_RENDER_OFFLOAD=1
    __NV_PRIME_RENDER_OFFLOAD_PROVIDER="${PULSAR_CORE_NVIDIA_PROVIDER:-NVIDIA-G0}"
    __GLX_VENDOR_LIBRARY_NAME=nvidia
    "${core_command[@]}"
  )

  printf '%s\n'     "Pulsar core NVIDIA PRIME offload enabled: ${PULSAR_CORE_NVIDIA_PROVIDER:-NVIDIA-G0}"     >>"$PULSAR_LOG_FILE"
fi

nohup "${core_command[@]}" >>"$PULSAR_LOG_FILE" 2>&1 &
core_pid=$!
echo "$core_pid" >"$PULSAR_PID_FILE"

if [[ "${PULSAR_DISPLAY_HOTPLUG_WATCH:-1}" == "1" ]]; then
  watch_display_topology "$core_pid" &
  display_watch_pid=$!
fi

wait_for_core || { tail -80 "$PULSAR_LOG_FILE" >&2; die "C++ core did not become ready."; }

if [[ "${PULSAR_RENDER_MAIN:-1}" == "1" && -x "$PULSAR_ROOT/core/scripts/place-sbs-window.py" ]]; then
  "$PULSAR_ROOT/core/scripts/place-sbs-window.py" >>"$PULSAR_LOG_FILE" 2>&1 || true
fi

browser="$(find_browser)" || die "No Chrome/Chromium browser was found. Run ./run.sh install-deps."
profile="$PULSAR_DATA_DIR/browser-profile"
mkdir -p "$profile"
browser_flags=(
  --kiosk "$PULSAR_BROWSER_URL"
  --window-position="${PULSAR_SETTINGS_X},${PULSAR_SETTINGS_Y}"
  --window-size="${PULSAR_SETTINGS_WIDTH},${PULSAR_SETTINGS_HEIGHT}"
  --force-device-scale-factor=1
  --user-data-dir="$profile"
  --no-first-run --no-default-browser-check --disable-session-crashed-bubble
  --disable-infobars --disable-translate --autoplay-policy=no-user-gesture-required
  --overscroll-history-navigation=0 --disable-pinch --disable-features=TranslateUI
  --enable-features=UseOzonePlatform --ozone-platform=x11 --use-gl=angle --use-angle=gl
  --touch-events=enabled
)
[[ "${PULSAR_BROWSER_GPU:-1}" == "1" ]] && browser_flags+=(--enable-gpu-rasterization --enable-zero-copy)
[[ $EUID -eq 0 ]] && browser_flags+=(--no-sandbox)

if [[ "${PULSAR_HIDE_CURSOR:-1}" == "1" ]] && [[ -x "$PULSAR_ROOT/core/scripts/hide-cursor.sh" ]]; then
  "$PULSAR_ROOT/core/scripts/hide-cursor.sh" >/dev/null 2>&1 &
  unclutter_pid=$!
fi
"$browser" "${browser_flags[@]}" >>"$PULSAR_DATA_DIR/browser.log" 2>&1 &
browser_pid=$!
wait "$core_pid"
