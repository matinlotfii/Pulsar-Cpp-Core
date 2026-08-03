#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_config

mkdir -p "$PULSAR_DATA_DIR"

combined_sink_name="${PULSAR_AUDIO_COMBINED_SINK_NAME:-pulsar_combined}"
output_volume="${PULSAR_AUDIO_OUTPUT_VOLUME:-125%}"
state_file="$PULSAR_DATA_DIR/audio.env"

wait_for_pactl() {
  local attempts="${PULSAR_AUDIO_PACTL_READY_ATTEMPTS:-30}"
  local delay="${PULSAR_AUDIO_PACTL_READY_DELAY_SEC:-0.5}"
  for _ in $(seq 1 "$attempts"); do
    if pactl info >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

ensure_pulseaudio() {
  command -v pactl >/dev/null 2>&1 || die "pactl is not installed."

  if pactl info >/dev/null 2>&1; then
    return 0
  fi

  pulseaudio --check >/dev/null 2>&1 || true
  pulseaudio --start --daemonize=yes --disallow-exit --exit-idle-time=-1 --log-target=journal >/dev/null 2>&1 || true
  wait_for_pactl || die "PulseAudio did not become ready."

  if ! pactl list short modules | awk '$2 == "module-switch-on-connect" { found = 1 } END { exit found ? 0 : 1 }'; then
    pactl load-module module-switch-on-connect >/dev/null 2>&1 || true
  fi
}

list_candidate_sinks() {
  pactl list short sinks 2>/dev/null | awk -v combined="$combined_sink_name" '
    $2 == combined { next }
    $2 ~ /\.monitor$/ { next }
    $2 ~ /auto_null/ { next }
    $2 ~ /usb-|hdmi|iec958/ { print $2 }
  ' | sort -u
}

unload_existing_combined_sink() {
  while read -r module_id; do
    [[ -n "$module_id" ]] || continue
    pactl unload-module "$module_id" >/dev/null 2>&1 || true
  done < <(
    pactl list short modules 2>/dev/null |
      awk -v combined="$combined_sink_name" '$0 ~ /module-combine-sink/ && $0 ~ ("sink_name=" combined) { print $1 }'
  )
}

set_sink_volume() {
  local sink="$1"
  [[ -n "$output_volume" ]] || return 0
  pactl set-sink-mute "$sink" 0 >/dev/null 2>&1 || true
  pactl set-sink-volume "$sink" "$output_volume" >/dev/null 2>&1 || true
}

write_state() {
  local default_sink="$1"
  shift
  local sinks=("$@")
  {
    printf 'PULSAR_AUDIO_DEFAULT_SINK=%s\n' "$default_sink"
    printf 'PULSAR_AUDIO_SINKS=%s\n' "$(IFS=,; echo "${sinks[*]}")"
  } >"$state_file"
}

configure_audio_outputs() {
  local sinks=()
  local combined_module_id=""
  local default_sink=""
  local slave_list=""

  mapfile -t sinks < <(list_candidate_sinks)
  if ((${#sinks[@]} == 0)); then
    warn "No digital PulseAudio sinks are available yet; audio routing is waiting."
    return 1
  fi

  for sink in "${sinks[@]}"; do
    set_sink_volume "$sink"
  done

  unload_existing_combined_sink

  if ((${#sinks[@]} == 1)); then
    default_sink="${sinks[0]}"
    pactl set-default-sink "$default_sink" >/dev/null 2>&1 || true
  else
    slave_list="$(IFS=,; echo "${sinks[*]}")"
    combined_module_id="$(
      pactl load-module module-combine-sink \
        sink_name="$combined_sink_name" \
        slaves="$slave_list" \
        adjust_time=0 \
        resample_method=trivial \
        remix=no
    )"
    default_sink="$combined_sink_name"
    pactl set-default-sink "$default_sink" >/dev/null 2>&1 || true
    set_sink_volume "$default_sink"
  fi

  write_state "$default_sink" "${sinks[@]}"
  log "Audio routing ready: default sink '${default_sink}' -> ${sinks[*]}."
  [[ -n "$combined_module_id" ]] || return 0
}

ensure_pulseaudio
configure_audio_outputs || exit 0
