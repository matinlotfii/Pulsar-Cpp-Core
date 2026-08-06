#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
load_config
[[ -f "$PULSAR_DATA_DIR/displays.env" ]] && source "$PULSAR_DATA_DIR/displays.env"

export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-/home/matin/.Xauthority}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/pulsar-runtime-matin}"
mkdir -p "$XDG_RUNTIME_DIR" "$PULSAR_DATA_DIR"

browser="$(find_browser)" || die "No Chrome/Chromium browser was found."
profile="$PULSAR_DATA_DIR/browser-profile"
pid_file="$PULSAR_DATA_DIR/browser.pid"
old_pid="$(cat "$pid_file" 2>/dev/null || true)"
if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
  kill -TERM "$old_pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "$old_pid" 2>/dev/null || break
    sleep 0.1
  done
fi
# Remove any stale kiosk process using this exact Pulsar browser profile.
pkill -TERM -f -- "--user-data-dir=$profile" 2>/dev/null || true
sleep 0.25

flags=(
  --kiosk "${PULSAR_BROWSER_URL:-http://127.0.0.1:4173}"
  --window-position="${PULSAR_SETTINGS_X:-0},${PULSAR_SETTINGS_Y:-0}"
  --window-size="${PULSAR_SETTINGS_WIDTH:-1024},${PULSAR_SETTINGS_HEIGHT:-600}"
  --force-device-scale-factor=1
  --user-data-dir="$profile"
  --no-first-run --no-default-browser-check --disable-session-crashed-bubble
  --disable-background-mode --disable-infobars --disable-translate
  --autoplay-policy=no-user-gesture-required
  --overscroll-history-navigation=0 --disable-pinch
  --disable-background-networking --disable-component-update --disable-sync
  --disable-features=AutofillServerCommunication,MediaRouter,OptimizationHints,PushMessagingBackgroundMode,TranslateUI
  --metrics-recording-only --password-store=basic --use-mock-keychain
  --enable-features=UseOzonePlatform --ozone-platform=x11 --use-gl=angle --use-angle=gl
  --touch-events=enabled
)
[[ "${PULSAR_BROWSER_GPU:-1}" == "1" ]] && flags+=(--enable-gpu-rasterization --enable-zero-copy)
[[ $EUID -eq 0 ]] && flags+=(--no-sandbox)

nohup "$browser" "${flags[@]}" >>"$PULSAR_DATA_DIR/browser.log" 2>&1 &
new_pid=$!
echo "$new_pid" >"$pid_file"
printf '%s\n' "Pulsar UI browser restarted live; Xorg and cameras stayed active." >>"$PULSAR_LOG_FILE"
