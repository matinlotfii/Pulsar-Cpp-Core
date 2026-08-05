#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
load_config
export DISPLAY="${DISPLAY:-:0}"

attempts="${PULSAR_DISPLAY_VERIFY_ATTEMPTS:-30}"
delay="${PULSAR_DISPLAY_VERIFY_DELAY:-0.5}"

output_active() {
  local output="$1"
  xrandr --query 2>/dev/null |
    awk -v wanted="$output" '
      $1 == wanted && $2 == "connected" {
        for (i=3; i<=NF; i++) {
          if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+/) found=1
        }
      }
      END { exit found ? 0 : 1 }
    '
}

state_ready() {
  local role output connected
  [[ -s "$PULSAR_DATA_DIR/displays.env" ]] || return 1

  set -a
  # shellcheck disable=SC1090
  source "$PULSAR_DATA_DIR/displays.env"
  set +a

  output="${PULSAR_SETTINGS_OUTPUT:-}"
  [[ -n "$output" ]] && output_active "$output" || return 1

  for role in DISPLAY AR1 AR2; do
    eval "output=\${PULSAR_ROLE_${role}_OUTPUT:-}"
    [[ -n "$output" ]] || continue
    eval "connected=\${PULSAR_ROLE_${role}_CONNECTED:-0}"
    [[ "$connected" == "1" ]] || return 1
    output_active "$output" || return 1
  done
}

for attempt in $(seq 1 "$attempts"); do
  if curl -fsS --max-time 1 \
      "http://${PULSAR_HOST:-127.0.0.1}:${PULSAR_PORT:-4173}/health" \
      >/dev/null 2>&1; then
    "$PULSAR_ROOT/core/scripts/configure-displays.sh" \
      >>"$PULSAR_LOG_FILE" 2>&1 || true

    if state_ready; then
      echo "Pulsar displays: OK"
      grep -E \
        '^(PULSAR_ROLE_(UI|DISPLAY|AR1|AR2)_(OUTPUT|CONNECTED|POSITION|PHYSICAL_MODE)|PULSAR_VIEWER_ACTIVE_(OUTPUTS|COUNT)|PULSAR_VIEWER_CANVAS_GEOMETRY)=' \
        "$PULSAR_DATA_DIR/displays.env" || true
      xrandr --query |
        grep -E '^(HDMI-2|DP-1-1|HDMI-1-0) connected' || true
      exit 0
    fi
  fi
  sleep "$delay"
done

echo "ERROR: HTTP is ready, but a configured display is still inactive." >&2
cat "$PULSAR_DATA_DIR/displays.env" >&2 2>/dev/null || true
xrandr --query >&2 2>/dev/null || true
tail -n 150 "$PULSAR_LOG_FILE" >&2 2>/dev/null || true
exit 1
