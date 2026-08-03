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
audio_watch_pid=""
touch_log_file="$PULSAR_DATA_DIR/touch.log"
session_shell_pid_file="$PULSAR_DATA_DIR/session-shell.pid"

place_sbs_window() {
  return 0
}

cleanup() {
  kill "$audio_watch_pid" "$display_watch_pid" "$browser_pid" "$core_pid" "$openbox_pid" "$unclutter_pid" 2>/dev/null || true
  rm -f "$PULSAR_PID_FILE"
  rm -f "$session_shell_pid_file"
}

request_session_rebuild() {
  printf '%s\n' "Pulsar session rebuild requested." >>"$PULSAR_LOG_FILE"
  exit 1
}

trap cleanup EXIT INT TERM
trap request_session_rebuild USR1

echo "$$" >"$session_shell_pid_file"

display_topology_signature() {
  local state connected
  state="$(xrandr --query 2>/dev/null || true)"
  [[ -n "$state" ]] || { printf '%s\n' "xrandr-unavailable"; return; }

  connected="$(awk '$2 == "connected" { print }' <<<"$state")"
  [[ -n "$connected" ]] || { printf '%s\n' "no-connected-output"; return; }

  # XRandR is the source of truth for this mixed Intel + NVIDIA GPU-screen
  # session. NVIDIA's DRM sysfs connector status can remain "disconnected"
  # even while HDMI-1-0 is connected and active through XRandR.
  printf '%s\n' "$connected" |
    sort |
    sha256sum |
    awk '{print $1}'
}

display_session_signature() {
  {
    printf '%s\n' \
      "${PULSAR_SETTINGS_OUTPUT:-}|${PULSAR_SETTINGS_WIDTH:-}x${PULSAR_SETTINGS_HEIGHT:-}+${PULSAR_SETTINGS_X:-}+${PULSAR_SETTINGS_Y:-}|${PULSAR_SETTINGS_MODE:-}@${PULSAR_SETTINGS_RATE:-}" \
      "${PULSAR_MAIN_OUTPUT:-}|${PULSAR_MAIN_WIDTH:-}x${PULSAR_MAIN_HEIGHT:-}+${PULSAR_MAIN_X:-}+${PULSAR_MAIN_Y:-}|${PULSAR_MAIN_MODE:-}@${PULSAR_MAIN_RATE:-}" \
      "${PULSAR_AR_LAYOUT:-mirror}|${PULSAR_RENDER_MAIN:-0}"
    if [[ "${PULSAR_AR_LAYOUT:-mirror}" == "extend" ]]; then
      printf '%s\n' \
        "${PULSAR_AR_OUTPUT:-}|${PULSAR_AR_WIDTH:-}x${PULSAR_AR_HEIGHT:-}+${PULSAR_AR_X:-}+${PULSAR_AR_Y:-}|${PULSAR_AR_MODE:-}@${PULSAR_AR_RATE:-}"
    fi
  } |
    sha256sum |
    awk '{print $1}'
}

display_aux_signature() {
  printf '%s\n' \
    "${PULSAR_AUX_OUTPUTS:-${PULSAR_AR_OUTPUT:-}}" \
    "${PULSAR_AUX_COUNT:-0}" \
    "${PULSAR_AUX_LAYOUT:-${PULSAR_AR_LAYOUT:-mirror}}" \
    "${PULSAR_AUX_MODES:-${PULSAR_AR_MODE:-}}" \
    "${PULSAR_AUX_RATES:-${PULSAR_AR_RATE:-}}" \
    "${PULSAR_AUX_GEOMETRIES:-}" |
    sha256sum |
    awk '{print $1}'
}

reload_display_env() {
  set -a
  # shellcheck disable=SC1090
  source "$PULSAR_DATA_DIR/displays.env"
  set +a
}

configure_audio_stack() {
  "$PULSAR_ROOT/core/scripts/configure-audio.sh" >>"$PULSAR_LOG_FILE" 2>&1 || true
}

audio_topology_signature() {
  command -v pactl >/dev/null 2>&1 || { printf '%s\n' "pactl-unavailable"; return; }
  if ! pactl info >/dev/null 2>&1; then
    printf '%s\n' "pulseaudio-unavailable"
    return
  fi

  local sinks
  sinks="$(
    pactl list short sinks 2>/dev/null |
      awk '$2 !~ /\.monitor$/ && $2 !~ /auto_null/ { print $2 }' |
      sort
  )"
  [[ -n "$sinks" ]] || { printf '%s\n' "no-sink"; return; }

  printf '%s\n' "$sinks" |
    sha256sum |
    awk '{print $1}'
}

reconfigure_display_topology() {
  local previous_settings_output="${PULSAR_SETTINGS_OUTPUT:-}"
  local previous_main_output="${PULSAR_MAIN_OUTPUT:-}"
  local previous_aux_outputs="${PULSAR_AUX_OUTPUTS:-${PULSAR_AR_OUTPUT:-}}"
  local previous_session_signature previous_aux_signature
  previous_session_signature="$(display_session_signature)"
  previous_aux_signature="$(display_aux_signature)"

  if ! "$PULSAR_ROOT/core/scripts/configure-displays.sh" >>"$PULSAR_LOG_FILE" 2>&1; then
    return 1
  fi
  reload_display_env

  local current_session_signature current_aux_signature
  current_session_signature="$(display_session_signature)"
  current_aux_signature="$(display_aux_signature)"

  if [[ "${PULSAR_SETTINGS_OUTPUT:-}" != "$previous_settings_output" ]] ||
     [[ "${PULSAR_MAIN_OUTPUT:-}" != "$previous_main_output" ]] ||
     [[ "$current_session_signature" != "$previous_session_signature" ]]; then
    printf '%s\n' \
      "Pulsar display hotplug: session layout changed from outputs ${previous_settings_output:-none}/${previous_main_output:-none}; scheduling full session rebuild." \
      >>"$PULSAR_LOG_FILE"
    return 2
  fi

  if [[ "$current_aux_signature" != "$previous_aux_signature" ]]; then
    printf '%s\n' \
      "Pulsar display hotplug: aux outputs changed from ${previous_aux_outputs:-none} to ${PULSAR_AUX_OUTPUTS:-${PULSAR_AR_OUTPUT:-none}}; applying live layout update." \
      >>"$PULSAR_LOG_FILE"
  else
    printf '%s\n' \
      "Pulsar display hotplug: layout refreshed in place." \
      >>"$PULSAR_LOG_FILE"
  fi

  place_sbs_window
  return 0
}

watch_display_topology() {
  local watched_core_pid="$1"
  local interval="${PULSAR_DISPLAY_HOTPLUG_INTERVAL:-2}"
  local debounce_samples="${PULSAR_DISPLAY_HOTPLUG_DEBOUNCE_SAMPLES:-3}"
  local startup_delay="${PULSAR_DISPLAY_HOTPLUG_START_DELAY:-4}"
  local baseline candidate current candidate_samples=0

  sleep "$startup_delay"
  kill -0 "$watched_core_pid" 2>/dev/null || return 0

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
        "Pulsar display hotplug: stable topology change detected; attempting live reconfiguration." \
        >>"$PULSAR_LOG_FILE"
      if reconfigure_display_topology; then
        baseline="$candidate"
        candidate_samples=0
        continue
      fi

      printf '%s\n' \
        "Pulsar display hotplug: live reconfiguration requires a full restart." \
        >>"$PULSAR_LOG_FILE"
      kill -TERM "$watched_core_pid" 2>/dev/null || true
      return 0
    fi
  done
}

watch_audio_topology() {
  local watched_core_pid="$1"
  local interval="${PULSAR_AUDIO_HOTPLUG_INTERVAL:-2}"
  local debounce_samples="${PULSAR_AUDIO_HOTPLUG_DEBOUNCE_SAMPLES:-2}"
  local startup_delay="${PULSAR_AUDIO_HOTPLUG_START_DELAY:-6}"
  local baseline candidate current candidate_samples=0

  sleep "$startup_delay"
  kill -0 "$watched_core_pid" 2>/dev/null || return 0

  configure_audio_stack
  baseline="$(audio_topology_signature)"
  candidate="$baseline"

  while kill -0 "$watched_core_pid" 2>/dev/null; do
    sleep "$interval"
    current="$(audio_topology_signature)"
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
        "Pulsar audio hotplug: stable sink change detected; refreshing audio routing." \
        >>"$PULSAR_LOG_FILE"
      configure_audio_stack
      baseline="$(audio_topology_signature)"
      candidate="$baseline"
      candidate_samples=0
    fi
  done
}

"$PULSAR_ROOT/core/scripts/configure-displays.sh"
reload_display_env

# Start the window manager before native/browser windows so placement and
# fullscreen state are deterministic on Ubuntu Server Xorg sessions.
xset s off >/dev/null 2>&1 || true
xset -dpms >/dev/null 2>&1 || true
xset s noblank >/dev/null 2>&1 || true
openbox >/dev/null 2>&1 &
openbox_pid=$!
sleep .4
configure_audio_stack
: >"$touch_log_file"
"$PULSAR_ROOT/core/scripts/configure-touch.sh" --watch --interval 2 >>"$touch_log_file" 2>&1 &

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

wait_for_core || { tail -80 "$PULSAR_LOG_FILE" >&2; die "C++ core did not become ready."; }

place_sbs_window

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
  --disable-background-mode --disable-infobars --disable-translate
  --autoplay-policy=no-user-gesture-required
  --overscroll-history-navigation=0 --disable-pinch
  --disable-background-networking --disable-component-update --disable-sync
  --disable-features=AutofillServerCommunication,MediaRouter,OptimizationHints,PushMessagingBackgroundMode,TranslateUI
  --metrics-recording-only --password-store=basic --use-mock-keychain
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

if [[ "${PULSAR_DISPLAY_HOTPLUG_WATCH:-1}" == "1" ]]; then
  watch_display_topology "$core_pid" &
  display_watch_pid=$!
fi

if [[ "${PULSAR_AUDIO_HOTPLUG_WATCH:-1}" == "1" ]]; then
  watch_audio_topology "$core_pid" &
  audio_watch_pid=$!
fi

wait "$core_pid"
