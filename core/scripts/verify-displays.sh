#!/usr/bin/env bash
set -Eeuo pipefail
# PULSAR_DISPLAY_TOUCH_VERIFY_V2
source "$(dirname "$0")/common.sh"
load_config
export DISPLAY="${DISPLAY:-:0}"

attempts="${PULSAR_DISPLAY_VERIFY_ATTEMPTS:-40}"
delay="${PULSAR_DISPLAY_VERIFY_DELAY:-0.5}"

read_state() {
  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      PULSAR_SETTINGS_OUTPUT|PULSAR_ROLE_DISPLAY_OUTPUT|PULSAR_ROLE_AR1_OUTPUT|PULSAR_ROLE_AR2_OUTPUT|PULSAR_ROLE_DISPLAY_CONNECTED|PULSAR_ROLE_AR1_CONNECTED|PULSAR_ROLE_AR2_CONNECTED|PULSAR_VIEWER_ACTIVE_COUNT|PULSAR_VIEWER_CANVAS_GEOMETRY)
        if [[ "$value" == \'*\' && ${#value} -ge 2 ]]; then
          value="${value:1:${#value}-2}"
        fi
        printf -v "$key" '%s' "$value"
        ;;
    esac
  done <"$PULSAR_DATA_DIR/displays.env"
}

output_active() {
  local output="$1"
  xrandr --query 2>/dev/null | awk -v wanted="$output" '
    $1 == wanted && $2 == "connected" {
      for (i=3; i<=NF; i++) {
        if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+/) found=1
      }
    }
    END { exit found ? 0 : 1 }
  '
}

current_rate() {
  local output="$1"
  xrandr --query 2>/dev/null | awk -v wanted="$output" '
    $1 == wanted && $2 == "connected" {inside=1; next}
    inside && /^[^[:space:]]/ {exit}
    inside && $1 ~ /^[0-9]+x[0-9]+$/ {
      for (i=2; i<=NF; i++) {
        if ($i ~ /\*/) {
          value=$i
          gsub(/[^0-9.]/, "", value)
          print value
          exit
        }
      }
    }
  '
}

rate_at_least() {
  local output="$1" minimum="$2" rate
  rate="$(current_rate "$output")"
  [[ -n "$rate" ]] || return 1
  awk -v value="$rate" -v minimum="$minimum" 'BEGIN { exit !((value+0) >= (minimum+0)) }'
}

find_touch_devices() {
  if [[ -n "${PULSAR_TOUCH_DEVICE_NAME:-}" ]]; then
    xinput --list --name-only | awk -v target="$PULSAR_TOUCH_DEVICE_NAME" '$0 == target {print}'
    return
  fi
  xinput --list --name-only |
    grep -Eiv 'virtual core|xwayland|keyboard|mouse|trackpad|touchpad' |
    grep -Ei 'touch|touchscreen|USB2IIC_CTP_CONTROL|wch\.cn|ctp|goodix|elan|eeti|ilitek|wave|hid.*touch' || true
}

touch_ready() {
  command -v xinput >/dev/null 2>&1 || return 1
  local name id enabled matrix found=1
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    id="$(xinput list --id-only "$name" 2>/dev/null || true)"
    [[ -n "$id" ]] || continue
    enabled="$(xinput list-props "$id" 2>/dev/null | awk -F: '/Device Enabled/{gsub(/[[:space:]]/,"",$2); print $2; exit}')"
    matrix="$(xinput list-props "$id" 2>/dev/null | awk -F: '/Coordinate Transformation Matrix/{print $2; exit}')"
    if [[ "$enabled" == "1" && -n "$matrix" ]]; then
      printf 'Touch device: %s (id=%s) matrix:%s\n' "$name" "$id" "$matrix"
      found=0
    fi
  done < <(find_touch_devices)
  return "$found"
}

state_ready() {
  [[ -s "$PULSAR_DATA_DIR/displays.env" ]] || return 1
  read_state
  [[ "${PULSAR_SETTINGS_OUTPUT:-}" == "HDMI-2" ]] || return 1
  [[ "${PULSAR_ROLE_DISPLAY_OUTPUT:-}" == "DP-1-1" ]] || return 1
  [[ "${PULSAR_ROLE_AR1_OUTPUT:-}" == "HDMI-1-0" ]] || return 1
  [[ "${PULSAR_ROLE_DISPLAY_CONNECTED:-0}" == "1" ]] || return 1
  [[ "${PULSAR_ROLE_AR1_CONNECTED:-0}" == "1" ]] || return 1
  [[ "${PULSAR_VIEWER_ACTIVE_COUNT:-0}" -ge 2 ]] || return 1
  output_active HDMI-2 || return 1
  output_active DP-1-1 || return 1
  output_active HDMI-1-0 || return 1
  rate_at_least DP-1-1 "${PULSAR_VERIFY_MAIN_MIN_RATE:-69}" || return 1
  rate_at_least HDMI-1-0 "${PULSAR_VERIFY_AR_MIN_RATE:-119}" || return 1
  return 0
}

for attempt in $(seq 1 "$attempts"); do
  if curl -fsS --max-time 1 \
      "http://${PULSAR_HOST:-127.0.0.1}:${PULSAR_PORT:-4173}/health" \
      >/dev/null 2>&1; then
    "$PULSAR_ROOT/core/scripts/configure-displays.sh" \
      >>"$PULSAR_LOG_FILE" 2>&1 || true
    "$PULSAR_ROOT/core/scripts/configure-touch.sh" \
      --watch --attempts 4 --interval 0.5 \
      >>"$PULSAR_DATA_DIR/touch.log" 2>&1 || true
    "$PULSAR_ROOT/core/scripts/place-sbs-window.py" \
      >>"$PULSAR_LOG_FILE" 2>&1 || true

    if state_ready &&
       { [[ "${PULSAR_REQUIRE_TOUCH:-1}" != "1" ]] || touch_ready; }; then
      echo "Pulsar display/touch verification: OK"
      echo "Main rate: $(current_rate DP-1-1) Hz"
      echo "Glasses rate: $(current_rate HDMI-1-0) Hz"
      grep -E \
        '^(PULSAR_SETTINGS_OUTPUT|PULSAR_ROLE_(DISPLAY|AR1)_(OUTPUT|CONNECTED|PHYSICAL_MODE|RATE|POSITION)|PULSAR_VIEWER_ACTIVE_COUNT|PULSAR_VIEWER_CANVAS_GEOMETRY)=' \
        "$PULSAR_DATA_DIR/displays.env" || true
      xrandr --query | grep -E '^(HDMI-2|DP-1-1|HDMI-1-0) connected' || true
      exit 0
    fi
  fi
  sleep "$delay"
done

echo "ERROR: Pulsar did not reach the required display/touch state." >&2
curl -fsS "http://127.0.0.1:${PULSAR_PORT:-4173}/health" >&2 2>/dev/null || true
echo >&2
cat "$PULSAR_DATA_DIR/displays.env" >&2 2>/dev/null || true
xrandr --query >&2 2>/dev/null || true
echo "--- touch devices ---" >&2
xinput --list >&2 2>/dev/null || true
echo "--- touch log ---" >&2
tail -n 160 "$PULSAR_DATA_DIR/touch.log" >&2 2>/dev/null || true
echo "--- Pulsar log ---" >&2
tail -n 200 "$PULSAR_LOG_FILE" >&2 2>/dev/null || true
exit 1
