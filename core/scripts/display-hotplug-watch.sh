#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/common.sh"
load_config

export DISPLAY="${DISPLAY:-:0}"
lock_file="$PULSAR_DATA_DIR/display-hotplug.lock"
pid_file="$PULSAR_DATA_DIR/display-hotplug.pid"
interval="${PULSAR_DISPLAY_HOTPLUG_INTERVAL:-0.5}"
debounce_samples="${PULSAR_DISPLAY_HOTPLUG_DEBOUNCE_SAMPLES:-2}"
refresh_helper="$PULSAR_ROOT/core/scripts/refresh-nvidia-outputs.sh"

mkdir -p "$PULSAR_DATA_DIR"
printf '%s\n' "$$" >"$pid_file"
exec 9>"$lock_file"

cleanup() {
  rm -f "$pid_file"
  [[ -n "${udev_pid:-}" ]] && kill "$udev_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

safe_usb_id() {
  local device="$1" vendor product
  [[ -r "$device/idVendor" && -r "$device/idProduct" ]] || return 1
  vendor="$(cat "$device/idVendor" 2>/dev/null || true)"
  product="$(cat "$device/idProduct" 2>/dev/null || true)"
  [[ -n "$vendor" && -n "$product" ]] || return 1
  printf '%s:%s\n' "${vendor,,}" "${product,,}"
}

topology_signature() {
  {
    timeout 4 xrandr --prop 2>/dev/null |
      awk '
        $2=="connected" || $2=="disconnected" {
          print "OUTPUT", $1, $2, $0
          output=$1
          inside=1
          edid=0
          next
        }
        inside && /^[^[:space:]]/ {inside=0; edid=0}
        inside && /^[[:space:]]*EDID:/ {edid=1; next}
        edid {
          line=$0
          gsub(/[[:space:]]/, "", line)
          if (line ~ /^[0-9a-fA-F]{32}$/) print "EDID", output, line
          else if (line!="") edid=0
        }
      '

    for status in /sys/class/drm/card*-*/status; do
      [[ -r "$status" ]] || continue
      printf 'DRM %s %s\n' "$(basename "$(dirname "$status")")" "$(cat "$status" 2>/dev/null || true)"
    done

    for device in /sys/bus/usb/devices/*; do
      id="$(safe_usb_id "$device" || true)"
      case "$id" in
        3318:0432|3318:0424|3318:0425)
          printf 'XREAL-USB %s %s\n' "$(basename "$device")" "$id"
          ;;
      esac
    done
  } | cksum | awk '{print $1 ":" $2}'
}

reconfigure() {
  flock -n 9 || return 0

  start_ns="$(date +%s%N)"
  [[ -x "$refresh_helper" ]] && "$refresh_helper" || true

  # Retry while the RTX performs DP link training. The configure script itself
  # also waits for stable EDID, so this remains bounded and non-blocking.
  if timeout 20 nice -n 10 ionice -c3 \
      "$PULSAR_ROOT/core/scripts/configure-displays.sh" \
      >>"$PULSAR_LOG_FILE" 2>&1; then
    end_ns="$(date +%s%N)"
    printf '%s\n' \
      "Pulsar display hotplug: monitor/two-glass layout applied live in $(((end_ns-start_ns)/1000000))ms." \
      >>"$PULSAR_LOG_FILE"
  else
    printf '%s\n' \
      "Pulsar display hotplug: RTX refresh did not settle; retrying on the next event/poll." \
      >>"$PULSAR_LOG_FILE"
  fi

  flock -u 9
}

# Configure once on watcher start, including a glass that was connected after
# the service launched but before this process began.
reconfigure || true
baseline="$(topology_signature || true)"
candidate="$baseline"
stable=0

# A DRM event shortens response time. The polling loop remains authoritative
# because NVIDIA reverse PRIME does not emit every connector event to udev.
if command -v udevadm >/dev/null 2>&1; then
  (
    udevadm monitor --udev --subsystem-match=drm 2>/dev/null |
      while IFS= read -r line; do
        [[ "$line" == UDEV* ]] || continue
        printf '%s\n' event >"$PULSAR_DATA_DIR/display-hotplug.event"
      done
  ) &
  udev_pid=$!
fi

while :; do
  sleep "$interval"

  current="$(topology_signature || true)"
  event_requested=0
  if [[ -f "$PULSAR_DATA_DIR/display-hotplug.event" ]]; then
    rm -f "$PULSAR_DATA_DIR/display-hotplug.event"
    event_requested=1
  fi

  if [[ "$current" == "$baseline" && "$event_requested" == "0" ]]; then
    candidate="$baseline"
    stable=0
    continue
  fi

  if [[ "$current" == "$candidate" ]]; then
    stable=$((stable+1))
  else
    candidate="$current"
    stable=1
  fi

  if ((event_requested==1 || stable>=debounce_samples)); then
    reconfigure || true
    baseline="$(topology_signature || true)"
    candidate="$baseline"
    stable=0
  fi
done
