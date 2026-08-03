#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_config

watch_mode=0
attempts=1
interval=2
bootloader_ids_regex='4348:55e0'
last_status=""
last_signature=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch)
      watch_mode=1
      attempts=0
      ;;
    --attempts)
      attempts="${2:?missing attempts value}"
      shift
      ;;
    --interval)
      interval="${2:?missing interval value}"
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

[[ -f "$PULSAR_DATA_DIR/displays.env" ]] || exit 0
command -v xinput >/dev/null 2>&1 || exit 0

reload_display_env() {
  [[ -f "$PULSAR_DATA_DIR/displays.env" ]] || return 1
  # shellcheck disable=SC1090
  source "$PULSAR_DATA_DIR/displays.env"
}

reload_display_env || exit 0
[[ -n "${PULSAR_SETTINGS_OUTPUT:-}" ]] || exit 0

touch_controller_in_bootloader() {
  command -v lsusb >/dev/null 2>&1 || return 1
  lsusb | grep -Eiq "[[:space:]]${bootloader_ids_regex}[[:space:]]"
}

find_touch_devices() {
  if [[ -n "${PULSAR_TOUCH_DEVICE_NAME:-}" ]]; then
    xinput --list --name-only | awk -v target="$PULSAR_TOUCH_DEVICE_NAME" '$0 == target { print }'
    return
  fi
  xinput --list --name-only | grep -Eiv 'virtual core|xwayland|keyboard|mouse|trackpad|touchpad' | \
    grep -Ei 'touch|touchscreen|USB2IIC_CTP_CONTROL|wch\.cn|ctp|goodix|elan|eeti|ilitek|wave|hid.*touch' || true
}

touch_device_fingerprints() {
  local touch_name touch_id
  while IFS= read -r touch_name; do
    [[ -n "$touch_name" ]] || continue
    touch_id="$(xinput list --id-only "$touch_name" 2>/dev/null || true)"
    [[ -n "$touch_id" ]] || continue
    printf '%s:%s\n' "$touch_id" "$touch_name"
  done < <(find_touch_devices)
}

output_ready() {
  command -v xrandr >/dev/null 2>&1 || return 0
  xrandr --query 2>/dev/null | awk -v output="$PULSAR_SETTINGS_OUTPUT" '$1 == output && $2 == "connected" { found = 1 } END { exit found ? 0 : 1 }'
}

current_touch_signature() {
  local bootloader_state output_state touch_fingerprints matrix
  if touch_controller_in_bootloader; then
    bootloader_state="bootloader"
  else
    bootloader_state="normal"
  fi
  if output_ready; then
    output_state="${PULSAR_SETTINGS_OUTPUT:-unset}"
  else
    output_state="output-unavailable"
  fi
  touch_fingerprints="$(touch_device_fingerprints | paste -sd, -)"
  matrix="$(output_matrix 2>/dev/null || true)"
  printf '%s|%s|%s|%s\n' \
    "$bootloader_state" \
    "$output_state" \
    "${touch_fingerprints:-no-touch-device}" \
    "${matrix:-no-matrix}"
}

log_status_once() {
  local status="$1"
  local signature="$2"
  if [[ "$status" != "$last_status" || "$signature" != "$last_signature" ]]; then
    case "$status" in
      bootloader)
        warn "Touch controller is still in WCH bootloader mode (${bootloader_ids_regex}); waiting for the real touchscreen device to re-enumerate."
        ;;
      no-output)
        warn "Settings output '$PULSAR_SETTINGS_OUTPUT' is not connected yet; touch mapping is waiting."
        ;;
      no-device)
        warn "No X11 touch device is currently visible; touch remapper is still watching."
        ;;
      mapped)
        log "Touch mapping is active on output '$PULSAR_SETTINGS_OUTPUT'."
        ;;
    esac
    last_status="$status"
    last_signature="$signature"
  fi
}

xinput_set_identity_matrix() {
  local touch_id="$1"
  xinput set-prop "$touch_id" "Coordinate Transformation Matrix" \
    1 0 0 0 1 0 0 0 1 >/dev/null 2>&1 || true
}

output_matrix() {
  command -v xrandr >/dev/null 2>&1 || return 1
  xrandr --listmonitors 2>/dev/null | awk -v target="$PULSAR_SETTINGS_OUTPUT" '
    NR > 1 {
      name = $NF
      geom = $(NF - 1)
      split(geom, pos, "+")
      split(pos[1], size_parts, "x")
      width = size_parts[1]
      height = size_parts[2]
      sub(/\/.*/, "", width)
      sub(/\/.*/, "", height)
      if (width != "" && height != "" && pos[2] != "" && pos[3] != "") {
        w[name] = width + 0
        h[name] = height + 0
        x[name] = pos[2] + 0
        y[name] = pos[3] + 0
        if (!seen) {
          minx = x[name]
          miny = y[name]
          maxx = x[name] + w[name]
          maxy = y[name] + h[name]
          seen = 1
        }
        if (x[name] < minx) minx = x[name]
        if (y[name] < miny) miny = y[name]
        if (x[name] + w[name] > maxx) maxx = x[name] + w[name]
        if (y[name] + h[name] > maxy) maxy = y[name] + h[name]
      }
    }
    END {
      if (!(target in w) || maxx <= minx || maxy <= miny) exit 1
      left = ENVIRON["PULSAR_TOUCH_INSET_LEFT"] + 0
      right = ENVIRON["PULSAR_TOUCH_INSET_RIGHT"] + 0
      top = ENVIRON["PULSAR_TOUCH_INSET_TOP"] + 0
      bottom = ENVIRON["PULSAR_TOUCH_INSET_BOTTOM"] + 0
      if (left < 0) left = 0
      if (right < 0) right = 0
      if (top < 0) top = 0
      if (bottom < 0) bottom = 0
      if (left + right >= 0.7) {
        left = 0
        right = 0
      }
      if (top + bottom >= 0.7) {
        top = 0
        bottom = 0
      }
      total_w = maxx - minx
      total_h = maxy - miny
      scale_x = (w[target] / total_w) / (1 - left - right)
      scale_y = (h[target] / total_h) / (1 - top - bottom)
      printf "%.6f 0 %.6f 0 %.6f %.6f 0 0 1\n",
        scale_x,
        (x[target] - minx) / total_w - (scale_x * left),
        scale_y,
        (y[target] - miny) / total_h - (scale_y * top)
    }
  '
}

map_touch_devices() {
  local touch_name touch_id mapped=1
  local matrix=""
  matrix="$(output_matrix || true)"
  while IFS= read -r touch_name; do
    [[ -n "$touch_name" ]] || continue
    touch_id="$(xinput list --id-only "$touch_name" 2>/dev/null || true)"
    [[ -n "$touch_id" ]] || continue
    xinput enable "$touch_id" >/dev/null 2>&1 || true
    xinput_set_identity_matrix "$touch_id"
    xinput map-to-output "$touch_id" "$PULSAR_SETTINGS_OUTPUT" >/dev/null 2>&1 || [[ -n "$matrix" ]] || continue
    if [[ -n "$matrix" ]]; then
      xinput set-prop "$touch_id" "Coordinate Transformation Matrix" \
        $matrix >/dev/null 2>&1 || true
    fi
    log "Mapped touch device '$touch_name' to output '$PULSAR_SETTINGS_OUTPUT'."
    mapped=0
  done < <(find_touch_devices)
  return "$mapped"
}

run_once() {
  local signature
  reload_display_env || return 1
  if touch_controller_in_bootloader; then
    signature="$(current_touch_signature)"
    log_status_once "bootloader" "$signature"
    return 2
  fi
  if ! output_ready; then
    signature="$(current_touch_signature)"
    log_status_once "no-output" "$signature"
    return 3
  fi
  if ! find_touch_devices | grep -q .; then
    signature="$(current_touch_signature)"
    log_status_once "no-device" "$signature"
    return 4
  fi
  signature="$(current_touch_signature)"
  if [[ "$last_status" == "mapped" && "$signature" == "$last_signature" ]]; then
    return 0
  fi
  map_touch_devices
  signature="$(current_touch_signature)"
  log_status_once "mapped" "$signature"
}

if [[ "$watch_mode" == "1" ]]; then
  iteration=0
  while :; do
    run_once || true
    iteration=$((iteration + 1))
    if ((attempts > 0 && iteration >= attempts)); then
      exit 0
    fi
    sleep "$interval"
  done
fi

run_once || exit 0
