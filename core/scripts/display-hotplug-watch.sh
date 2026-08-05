#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/common.sh"
load_config

lock_file="$PULSAR_DATA_DIR/display-hotplug.lock"
pid_file="$PULSAR_DATA_DIR/display-hotplug.pid"
interval="${PULSAR_DISPLAY_HOTPLUG_INTERVAL:-1}"
debounce_samples="${PULSAR_DISPLAY_HOTPLUG_DEBOUNCE_SAMPLES:-2}"

mkdir -p "$PULSAR_DATA_DIR"
printf '%s\n' "$$" >"$pid_file"

exec 9>"$lock_file"

cleanup() {
  rm -f "$pid_file"
}

trap cleanup EXIT INT TERM

topology_signature() {
  timeout 5 xrandr --prop 2>/dev/null |
    awk '
      $2 == "connected" || $2 == "disconnected" {
        print "OUTPUT", $1, $2

        if ($2 == "connected") {
          for (i = 3; i <= NF; i++) {
            if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+/) {
              print "GEOMETRY", $1, $i
            }
          }
        }

        output = $1
        inside = 1
        edid = 0
        next
      }

      inside && /^[^[:space:]]/ {
        inside = 0
        edid = 0
      }

      inside && /^[[:space:]]*EDID:/ {
        edid = 1
        next
      }

      edid {
        line = $0
        gsub(/[[:space:]]/, "", line)

        if (line ~ /^[0-9a-fA-F]{32}$/) {
          print "EDID", output, line
        } else if (line != "") {
          edid = 0
        }
      }
    ' |
    cksum |
    awk '{print $1 ":" $2}'
}

assigned_output_inactive() {
  local query key output

  [[ -f "$PULSAR_DATA_DIR/displays.env" ]] || return 1

  query="$(timeout 5 xrandr --query 2>/dev/null || true)"

  while IFS='=' read -r key output; do
    case "$key" in
      PULSAR_SETTINGS_OUTPUT|\
      PULSAR_ROLE_DISPLAY_OUTPUT|\
      PULSAR_ROLE_AR1_OUTPUT|\
      PULSAR_ROLE_AR2_OUTPUT)
        [[ -n "$output" ]] || continue

        awk -v target="$output" '
          $1 == target && $2 == "connected" {
            connected = 1

            for (i = 3; i <= NF; i++) {
              if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+/) {
                active = 1
              }
            }
          }

          END {
            exit connected && !active ? 0 : 1
          }
        ' <<<"$query" &&
          return 0
        ;;
    esac
  done <"$PULSAR_DATA_DIR/displays.env"

  return 1
}

last_signature="$(topology_signature || true)"
candidate_signature=""
stable_count=0

while :; do
  sleep "$interval"

  current_signature="$(topology_signature || true)"
  repair=0

  if [[ -n "$current_signature" &&
        "$current_signature" != "$last_signature" ]]; then

    if [[ "$current_signature" == "$candidate_signature" ]]; then
      stable_count=$((stable_count + 1))
    else
      candidate_signature="$current_signature"
      stable_count=1
    fi

    if ((stable_count >= debounce_samples)); then
      repair=1
    fi
  else
    candidate_signature=""
    stable_count=0
  fi

  assigned_output_inactive &&
    repair=1

  ((repair == 1)) || continue

  flock -n 9 || continue

  if timeout 20 \
      "$PULSAR_ROOT/core/scripts/configure-displays.sh" \
      >>"$PULSAR_LOG_FILE" 2>&1; then

    last_signature="$(topology_signature || true)"
    candidate_signature=""
    stable_count=0

    printf '%s\n' \
      "Pulsar display watch: monitor and up to two XREAL glasses refreshed without restarting the camera service." \
      >>"$PULSAR_LOG_FILE"
  else
    printf '%s\n' \
      "Pulsar display watch: topology refresh failed; retrying without blocking video." \
      >>"$PULSAR_LOG_FILE"
  fi

  flock -u 9
done
