#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_config
mkdir -p "$PULSAR_DATA_DIR"

"$PULSAR_ROOT/core/scripts/configure-displays.sh"
set -a
# shellcheck disable=SC1090
source "$PULSAR_DATA_DIR/displays.env"
set +a

# Start the window manager before native/browser windows so placement and
# fullscreen state are deterministic on Ubuntu Server Xorg sessions.
openbox >/dev/null 2>&1 &
openbox_pid=$!
sleep .4

if [[ -f "$PULSAR_PID_FILE" ]] && kill -0 "$(cat "$PULSAR_PID_FILE")" 2>/dev/null; then
  kill "$(cat "$PULSAR_PID_FILE")" || true
  sleep .4
fi

nohup "$PULSAR_BINARY" --ui-root "$PULSAR_ROOT/ui/dist" --data-root "$PULSAR_DATA_DIR" >>"$PULSAR_LOG_FILE" 2>&1 &
core_pid=$!
echo "$core_pid" >"$PULSAR_PID_FILE"
cleanup() {
  kill "$core_pid" "$openbox_pid" 2>/dev/null || true
  rm -f "$PULSAR_PID_FILE"
}
trap cleanup EXIT INT TERM
wait_for_core || { tail -80 "$PULSAR_LOG_FILE" >&2; die "C++ core did not become ready."; }

browser="$(find_browser)" || die "No Chrome/Chromium browser was found. Run ./run.sh install-deps."
profile="$PULSAR_DATA_DIR/browser-profile"
mkdir -p "$profile"
browser_flags=(
  --kiosk "$PULSAR_BROWSER_URL"
  --window-position="${PULSAR_SETTINGS_X},${PULSAR_SETTINGS_Y}"
  --window-size="${PULSAR_SETTINGS_WIDTH},${PULSAR_SETTINGS_HEIGHT}"
  --user-data-dir="$profile"
  --no-first-run --no-default-browser-check --disable-session-crashed-bubble
  --disable-infobars --disable-translate --autoplay-policy=no-user-gesture-required
  --overscroll-history-navigation=0 --disable-pinch --disable-features=TranslateUI
)
[[ "${PULSAR_BROWSER_GPU:-1}" == "1" ]] && browser_flags+=(--use-gl=desktop --enable-gpu-rasterization)
[[ $EUID -eq 0 ]] && browser_flags+=(--no-sandbox)

if [[ "${PULSAR_HIDE_CURSOR:-1}" == "1" ]] && command -v unclutter >/dev/null 2>&1; then
  unclutter -idle 0.5 -root >/dev/null 2>&1 &
fi
"$browser" "${browser_flags[@]}" >>"$PULSAR_DATA_DIR/browser.log" 2>&1 &
wait "$core_pid"
