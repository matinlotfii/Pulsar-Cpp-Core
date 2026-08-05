#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
load_config
command -v xrandr >/dev/null 2>&1 || die "xrandr is not installed."

mkdir -p "$PULSAR_DATA_DIR"
state="$(timeout 5 xrandr --query)"
mapfile -t all_outputs < <(awk '$2=="connected" || $2=="disconnected" {print $1}' <<<"$state")
mapfile -t connected_outputs < <(awk '$2=="connected" {print $1}' <<<"$state")
((${#connected_outputs[@]} > 0)) || die "No connected X11 display was detected."

contains() {
  local wanted="$1" item
  shift || true
  for item in "$@"; do [[ "$item" == "$wanted" ]] && return 0; done
  return 1
}
is_connected() { contains "$1" "${connected_outputs[@]}"; }
is_known() { contains "$1" "${all_outputs[@]}"; }

supports_mode() {
  local output="$1" wanted="$2"
  awk -v out="$output" -v wanted="$wanted" '
    $1==out && $2=="connected" {inside=1; next}
    inside && /^[^[:space:]]/ {exit}
    inside && $1==wanted {found=1; exit}
    END {exit found ? 0 : 1}
  ' <<<"$state"
}

preferred_mode() {
  local output="$1"
  awk -v out="$output" '
    $1==out && $2=="connected" {inside=1; next}
    inside && /^[^[:space:]]/ {inside=0}
    inside && $1 ~ /^[0-9]+x[0-9]+$/ {
      if ($0 ~ /\+/) {print $1; exit}
      if (fallback=="") fallback=$1
    }
    END {if (fallback!="") print fallback}
  ' <<<"$state" | head -n1
}

best_rate() {
  local output="$1" mode="$2" role="$3"
  local rates
  rates="$(awk -v out="$output" -v mode="$mode" '
    function clean(v) {gsub(/[^0-9.]/,"",v); return v}
    $1==out && $2=="connected" {inside=1; next}
    inside && /^[^[:space:]]/ {exit}
    inside && $1==mode {
      for (i=2;i<=NF;i++) {
        value=clean($i)
        if (value ~ /^[0-9]+([.][0-9]+)?$/) print value
      }
      exit
    }
  ' <<<"$state")"
  [[ -n "$rates" ]] || return 0
  if [[ "$role" == "display" ]]; then
    awk '$1 >= 59 && $1 <= 61 {print; exit}' <<<"$(sort -nr <<<"$rates")" || true
  else
    awk '$1 <= 120.1 && $1 >= 59 {print; exit}' <<<"$(sort -nr <<<"$rates")" || true
  fi
}

mode_dimensions() {
  local mode="$1"
  if [[ "$mode" =~ ^([0-9]+)x([0-9]+)$ ]]; then
    printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf '1920 1080\n'
  fi
}

# Settings/UI output is not part of the camera viewer canvas.
settings="${PULSAR_ROLE_UI_OUTPUT:-${PULSAR_PREFERRED_SETTINGS_OUTPUT:-HDMI-2}}"
if [[ -z "$settings" ]] || ! is_connected "$settings"; then
  settings="${connected_outputs[0]}"
  smallest_area=999999999
  for output in "${connected_outputs[@]}"; do
    mode="$(preferred_mode "$output")"
    read -r w h < <(mode_dimensions "$mode")
    area=$((w*h))
    if ((area < smallest_area)); then
      smallest_area=$area
      settings="$output"
    fi
  done
fi

# Exactly three independent camera endpoints: one monitor and two glasses.
display="${PULSAR_ROLE_DISPLAY_OUTPUT:-}"
ar1="${PULSAR_ROLE_AR1_OUTPUT:-}"
ar2="${PULSAR_ROLE_AR2_OUTPUT:-}"

valid_role_connector() {
  [[ -n "$1" ]] && is_known "$1" && [[ "$1" != "$settings" ]]
}
valid_role_connector "$display" || display=""
valid_role_connector "$ar1" || ar1=""
valid_role_connector "$ar2" || ar2=""

used=("$settings")
[[ -n "$display" ]] && used+=("$display")
[[ -n "$ar1" ]] && used+=("$ar1")
[[ -n "$ar2" ]] && used+=("$ar2")

unused_connected() {
  local output
  for output in "${connected_outputs[@]}"; do
    [[ "$output" == "$settings" ]] && continue
    contains "$output" "${used[@]}" && continue
    printf '%s\n' "$output"
  done
}

# Prefer HDMI/DVI for the 2D monitor and DP for glasses.
if [[ -z "$display" ]]; then
  while IFS= read -r output; do
    case "$output" in HDMI-*|DVI-*) display="$output"; used+=("$output"); break ;; esac
  done < <(unused_connected)
fi
if [[ -z "$display" ]]; then
  output="$(unused_connected | head -n1 || true)"
  [[ -n "$output" ]] && { display="$output"; used+=("$output"); }
fi

for role_name in ar1 ar2; do
  [[ -n "${!role_name}" ]] && continue
  selected=""
  while IFS= read -r output; do
    case "$output" in DP-*|HDMI-1-*|DVI-*) selected="$output"; break ;; esac
  done < <(unused_connected)
  [[ -n "$selected" ]] || selected="$(unused_connected | head -n1 || true)"
  if [[ -n "$selected" ]]; then
    printf -v "$role_name" '%s' "$selected"
    used+=("$selected")
  fi
done

settings_mode="$(preferred_mode "$settings")"
[[ -n "$settings_mode" ]] || settings_mode="1024x600"
read -r settings_w settings_h < <(mode_dimensions "$settings_mode")

monitor_w="${PULSAR_MONITOR_LOGICAL_WIDTH:-1920}"
monitor_h="${PULSAR_MONITOR_LOGICAL_HEIGHT:-1080}"
glass_w="${PULSAR_GLASS_LOGICAL_WIDTH:-3840}"
glass_h="${PULSAR_GLASS_LOGICAL_HEIGHT:-1080}"

roles=(display ar-glass-1 ar-glass-2)
connectors=("$display" "$ar1" "$ar2")
logical_ws=("$monitor_w" "$glass_w" "$glass_w")
logical_hs=("$monitor_h" "$glass_h" "$glass_h")
connected_flags=(0 0 0)
physical_modes=(none none none)
logical_modes=("${monitor_w}x${monitor_h}" "${glass_w}x${glass_h}" "${glass_w}x${glass_h}")
rates=(off off off)
positions=(none none none)
active_outputs=()
active_glasses=()
panel_specs=()

# Discover the compact logical canvas before applying outputs.
canvas_w=0
canvas_h=1
for index in 0 1 2; do
  output="${connectors[$index]}"
  if [[ -n "$output" ]] && is_connected "$output"; then
    connected_flags[$index]=1
    canvas_w=$((canvas_w + logical_ws[index]))
    ((logical_hs[index] > canvas_h)) && canvas_h="${logical_hs[$index]}"
  fi
done
# Keep a tiny valid viewer surface if no camera endpoint is connected.
((canvas_w > 0)) || canvas_w=1
((canvas_h > 0)) || canvas_h=1
canvas_x="$settings_w"
canvas_y=0
fb_w=$((canvas_x + canvas_w))
fb_h=$((settings_h > canvas_h ? settings_h : canvas_h))

# Disable viewer outputs first, apply the UI output, then resize framebuffer.
for output in "${connected_outputs[@]}"; do
  [[ "$output" == "$settings" ]] && continue
  xrandr --output "$output" --off 2>/dev/null || true
done
xrandr --output "$settings" --mode "$settings_mode" --pos 0x0 --primary
xrandr --fb "${fb_w}x${fb_h}" 2>/dev/null || true

cursor_x="$canvas_x"
for index in 0 1 2; do
  role="${roles[$index]}"
  output="${connectors[$index]}"
  logical_w="${logical_ws[$index]}"
  logical_h="${logical_hs[$index]}"
  [[ "${connected_flags[$index]}" == "1" ]] || continue

  native_mode="$(preferred_mode "$output")"
  [[ -n "$native_mode" ]] || native_mode="1920x1080"
  physical_mode="$native_mode"
  requested_mode="${logical_w}x${logical_h}"
  rate=""
  applied=0

  if supports_mode "$output" "$requested_mode"; then
    physical_mode="$requested_mode"
    rate="$(best_rate "$output" "$physical_mode" "$role")"
    args=(--output "$output" --mode "$physical_mode" --pos "${cursor_x}x0" --rotate normal)
    [[ -n "$rate" ]] && args+=(--rate "$rate")
    if xrandr "${args[@]}"; then applied=1; fi
  fi

  if ((applied == 0)); then
    rate="$(best_rate "$output" "$native_mode" "$role")"
    # The logical 3840x1080 SBS surface is scaled by the GPU when the glasses'
    # EDID exposes only 1920x1080. This preserves independent 3D composition,
    # but the physical pixel count remains limited by the glasses hardware.
    args=(--output "$output" --mode "$native_mode" --scale-from "${logical_w}x${logical_h}" --pos "${cursor_x}x0" --rotate normal)
    [[ -n "$rate" ]] && args+=(--rate "$rate")
    if xrandr "${args[@]}"; then
      applied=1
      physical_mode="$native_mode"
    fi
  fi

  if ((applied == 0)); then
    # Conservative fallback: use native scanout and expose the physical panel
    # size to the renderer, avoiding a broken XRandR topology.
    read -r logical_w logical_h < <(mode_dimensions "$native_mode")
    logical_ws[$index]="$logical_w"
    logical_hs[$index]="$logical_h"
    requested_mode="${logical_w}x${logical_h}"
    xrandr --output "$output" --mode "$native_mode" --pos "${cursor_x}x0" --rotate normal
    physical_mode="$native_mode"
  fi

  physical_modes[$index]="$physical_mode"
  rates[$index]="${rate:-auto}"
  positions[$index]="${cursor_x}x0"
  panel_x=$((cursor_x - canvas_x))
  panel_specs+=("${index}:${logical_w}x${logical_h}+${panel_x}+0")
  active_outputs+=("$output")
  ((index > 0)) && active_glasses+=("$output")
  cursor_x=$((cursor_x + logical_w))
done

# Recompute the live canvas after any native-mode fallback.
live_canvas_w=$((cursor_x - canvas_x))
((live_canvas_w > 0)) || live_canvas_w=1
live_canvas_h=1
for index in 0 1 2; do
  [[ "${connected_flags[$index]}" == "1" ]] || continue
  ((logical_hs[index] > live_canvas_h)) && live_canvas_h="${logical_hs[$index]}"
done
xrandr --fb "$((canvas_x + live_canvas_w))x$((settings_h > live_canvas_h ? settings_h : live_canvas_h))" 2>/dev/null || true

# Turn off connected outputs not assigned to UI/monitor/two glasses.
for output in "${connected_outputs[@]}"; do
  [[ "$output" == "$settings" ]] && continue
  contains "$output" "${connectors[@]}" && continue
  xrandr --output "$output" --off 2>/dev/null || true
done

active_csv="$(IFS=,; echo "${active_outputs[*]}")"
glass_csv="$(IFS=,; echo "${active_glasses[*]}")"
connector_csv="$(IFS=,; echo "${connectors[*]}")"
panel_spec_string="$(IFS=';'; echo "${panel_specs[*]}")"
main_output="${display:-${ar1:-${ar2:-}}}"
generation="$(date +%s%N)"

# Renderer layout is independent of the process environment and is reloaded
# live by SbsRenderer on every atomic file update.
layout_tmp="$PULSAR_DATA_DIR/viewer-layout.env.tmp.$$"
cat >"$layout_tmp" <<ENV
PULSAR_VIEWER_LAYOUT_GENERATION=$generation
PULSAR_VIEWER_CANVAS_GEOMETRY=${live_canvas_w}x${live_canvas_h}+${canvas_x}+${canvas_y}
PULSAR_VIEWER_PANEL_SPECS=$panel_spec_string
PULSAR_VIEWER_PROFILE_COUNT=3
ENV
mv -f "$layout_tmp" "$PULSAR_DATA_DIR/viewer-layout.env"

env_tmp="$PULSAR_DATA_DIR/displays.env.tmp.$$"
cat >"$env_tmp" <<ENV
PULSAR_SETTINGS_OUTPUT=$settings
PULSAR_SETTINGS_WIDTH=$settings_w
PULSAR_SETTINGS_HEIGHT=$settings_h
PULSAR_SETTINGS_X=0
PULSAR_SETTINGS_Y=0
PULSAR_SETTINGS_MODE=$settings_mode
PULSAR_MAIN_OUTPUT=$main_output
PULSAR_MAIN_WIDTH=$monitor_w
PULSAR_MAIN_HEIGHT=$monitor_h
PULSAR_MAIN_X=$canvas_x
PULSAR_MAIN_Y=$canvas_y
PULSAR_MAIN_MODE=${monitor_w}x${monitor_h}
PULSAR_RENDER_MAIN=1
PULSAR_ROLE_UI_OUTPUT=$settings
PULSAR_ROLE_DISPLAY_OUTPUT=$display
PULSAR_ROLE_AR1_OUTPUT=$ar1
PULSAR_ROLE_AR2_OUTPUT=$ar2
PULSAR_ROLE_DISPLAY_CONNECTED=${connected_flags[0]}
PULSAR_ROLE_AR1_CONNECTED=${connected_flags[1]}
PULSAR_ROLE_AR2_CONNECTED=${connected_flags[2]}
PULSAR_ROLE_DISPLAY_LOGICAL_MODE=${logical_ws[0]}x${logical_hs[0]}
PULSAR_ROLE_AR1_LOGICAL_MODE=${logical_ws[1]}x${logical_hs[1]}
PULSAR_ROLE_AR2_LOGICAL_MODE=${logical_ws[2]}x${logical_hs[2]}
PULSAR_ROLE_DISPLAY_PHYSICAL_MODE=${physical_modes[0]}
PULSAR_ROLE_AR1_PHYSICAL_MODE=${physical_modes[1]}
PULSAR_ROLE_AR2_PHYSICAL_MODE=${physical_modes[2]}
PULSAR_ROLE_DISPLAY_RATE=${rates[0]}
PULSAR_ROLE_AR1_RATE=${rates[1]}
PULSAR_ROLE_AR2_RATE=${rates[2]}
PULSAR_ROLE_DISPLAY_POSITION=${positions[0]}
PULSAR_ROLE_AR1_POSITION=${positions[1]}
PULSAR_ROLE_AR2_POSITION=${positions[2]}
PULSAR_VIEWER_OUTPUTS_BY_PROFILE=$connector_csv
PULSAR_VIEWER_ACTIVE_OUTPUTS=$active_csv
PULSAR_VIEWER_ACTIVE_COUNT=${#active_outputs[@]}
PULSAR_VIEWER_CANVAS_X=$canvas_x
PULSAR_VIEWER_CANVAS_Y=$canvas_y
PULSAR_VIEWER_CANVAS_WIDTH=$live_canvas_w
PULSAR_VIEWER_CANVAS_HEIGHT=$live_canvas_h
PULSAR_VIEWER_CANVAS_GEOMETRY=${live_canvas_w}x${live_canvas_h}+${canvas_x}+${canvas_y}
PULSAR_VIEWER_PANEL_SPECS=$panel_spec_string
PULSAR_AUX_OUTPUTS=$glass_csv
PULSAR_AUX_COUNT=${#active_glasses[@]}
PULSAR_AUX_LAYOUT=extend
PULSAR_RTX_VIEWER_OUTPUTS=$active_csv
PULSAR_RTX_VIEWER_COUNT=${#active_outputs[@]}
PULSAR_RTX_MIRROR_OUTPUTS=
PULSAR_RTX_MIRROR_COUNT=0
ENV
mv -f "$env_tmp" "$PULSAR_DATA_DIR/displays.env"

log "Independent outputs: UI=$settings monitor=${display:-none} glass1=${ar1:-none} glass2=${ar2:-none} active=${active_csv:-none} canvas=${live_canvas_w}x${live_canvas_h}+${canvas_x}+0"
