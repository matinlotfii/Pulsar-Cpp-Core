#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/common.sh"
load_config
export DISPLAY="${DISPLAY:-:0}"

routing="$PULSAR_DATA_DIR/display-routing.env"
displays="$PULSAR_DATA_DIR/displays.env"

[[ -f "$routing" && -f "$displays" ]] || {
  echo "ERROR: display routing state is missing." >&2
  exit 1
}

cat "$routing"
echo

grep -E \
  'PULSAR_ROLE_(DISPLAY|AR1|AR2)_(OUTPUT|CONNECTED|PHYSICAL_MODE|RATE|POSITION|EDID|INPUT_LAYOUT)|PULSAR_VIEWER_(ACTIVE_OUTPUTS|ACTIVE_COUNT|CANVAS_GEOMETRY|PANEL_SPECS)' \
  "$displays"

echo
xrandr --query | grep -E '^(HDMI-2|HDMI-[0-9]+-[0-9]+|DP-[0-9]+-[0-9]+) connected'

echo
xwininfo -root -tree 2>/dev/null | grep 'Pulsar Multi-Output Viewer' || true

echo
pgrep -af 'display-hotplug-watch.sh' || true
