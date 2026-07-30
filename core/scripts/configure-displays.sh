#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_config
command -v xrandr >/dev/null 2>&1 || die "xrandr is not installed."

xrandr_state="$(xrandr --query)"
mapfile -t outputs < <(awk '$2=="connected" {print $1}' <<<"$xrandr_state")
((${#outputs[@]} > 0)) || die "No connected X11 display was detected."

preferred_mode() {
  local output="$1"
  awk -v out="$output" '
    $1==out && $2=="connected" {inside=1; next}
    inside && /^[^[:space:]]/ {exit}
    inside && /[+*]/ {gsub(/^[[:space:]]+/,""); print $1; exit}
  ' <<<"$xrandr_state"
}

area_for() {
  local mode="$1" w h
  w="${mode%x*}"; h="${mode#*x}"
  [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]] || { echo 0; return; }
  echo $((w * h))
}

# The settings screen is the smallest connected display. The SBS screen must
# be a different output, even when both displays have exactly the same size.
settings="${outputs[0]}"
min_area=999999999
for output in "${outputs[@]}"; do
  mode="$(preferred_mode "$output")"; [[ -n "$mode" ]] || mode="1024x768"
  area="$(area_for "$mode")"
  if ((area < min_area)); then min_area=$area; settings=$output; fi
done

main="$settings"
max_area=-1
if ((${#outputs[@]} >= 2)); then
  for output in "${outputs[@]}"; do
    [[ "$output" == "$settings" ]] && continue
    mode="$(preferred_mode "$output")"; [[ -n "$mode" ]] || mode="1024x768"
    area="$(area_for "$mode")"
    if ((area > max_area)); then max_area=$area; main=$output; fi
  done
fi

apply_output_mode() {
  local output="$1" position_args=("${@:2}") mode
  mode="$(preferred_mode "$output")"
  if [[ -n "$mode" ]]; then
    xrandr --output "$output" --mode "$mode" "${position_args[@]}"
  else
    xrandr --output "$output" --auto "${position_args[@]}"
  fi
}

if ((${#outputs[@]} >= 2)); then
  apply_output_mode "$settings" --pos 0x0 --primary
  apply_output_mode "$main" --right-of "$settings"
  render_main=1
else
  apply_output_mode "$settings" --pos 0x0 --primary
  render_main=0
fi

# Read the final X11 geometry after applying the layout.
xrandr_state="$(xrandr --query)"
geometry="$(awk -v out="$settings" '$1==out && $2=="connected" {for(i=3;i<=NF;i++) if($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+/) {print $i; exit}}' <<<"$xrandr_state")"
if [[ "$geometry" =~ ^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$ ]]; then
  settings_width="${BASH_REMATCH[1]}"
  settings_height="${BASH_REMATCH[2]}"
  settings_x="${BASH_REMATCH[3]}"
  settings_y="${BASH_REMATCH[4]}"
else
  settings_width=1024; settings_height=768; settings_x=0; settings_y=0
fi

mkdir -p "$PULSAR_DATA_DIR"
cat >"$PULSAR_DATA_DIR/displays.env" <<ENV
PULSAR_SETTINGS_OUTPUT=$settings
PULSAR_MAIN_OUTPUT=$main
PULSAR_SETTINGS_WIDTH=$settings_width
PULSAR_SETTINGS_HEIGHT=$settings_height
PULSAR_SETTINGS_X=$settings_x
PULSAR_SETTINGS_Y=$settings_y
PULSAR_RENDER_MAIN=$render_main
ENV
log "Settings display: $settings; SBS display: $main; native SBS: $render_main"
