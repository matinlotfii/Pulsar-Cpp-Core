#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/common.sh"
load_config
command -v xrandr >/dev/null 2>&1 || die "xrandr is not installed."

state="$(xrandr --query)"
mapfile -t connected < <(awk '$2=="connected" {print $1}' <<<"$state")
((${#connected[@]} > 0)) || die "No connected X11 display was detected."

is_connected() {
  local wanted="$1" item
  for item in "${connected[@]}"; do
    [[ "$item" == "$wanted" ]] && return 0
  done
  return 1
}

mode_area() {
  local output="$1" mode
  mode="$(awk -v out="$output" '
    $1==out && $2=="connected" {inside=1; next}
    inside && /^[^[:space:]]/ {inside=0}
    inside && $1 ~ /^[0-9]+x[0-9]+$/ {
      if ($0 ~ /\+/) {print $1; exit}
      if (fallback=="") fallback=$1
    }
    END {if (fallback!="") print fallback}
  ' <<<"$state" | head -n1)"
  [[ "$mode" =~ ^([0-9]+)x([0-9]+)$ ]] || { echo 999999999; return; }
  echo $((BASH_REMATCH[1] * BASH_REMATCH[2]))
}

supports_mode() {
  local output="$1" wanted="$2"
  awk -v out="$output" -v wanted="$wanted" '
    $1==out && $2=="connected" {inside=1; next}
    inside && /^[^[:space:]]/ {exit}
    inside && $1==wanted {found=1; exit}
    END {exit found ? 0 : 1}
  ' <<<"$state"
}

current_geometry() {
  local output="$1"
  awk -v out="$output" '$1==out && $2=="connected" {
    for (i=3;i<=NF;i++) if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+/) {print $i; exit}
  }' <<<"$(xrandr --query)"
}

settings="${PULSAR_PREFERRED_SETTINGS_OUTPUT:-}"
if [[ -z "$settings" ]] || ! is_connected "$settings"; then
  settings="${connected[0]}"
  best=999999999
  for output in "${connected[@]}"; do
    area="$(mode_area "$output")"
    if ((area < best)); then
      best="$area"
      settings="$output"
    fi
  done
fi

viewers=()
for output in "${connected[@]}"; do
  [[ "$output" == "$settings" ]] && continue
  case "$output" in
    DP-*|HDMI-1-*|DVI-*) viewers+=("$output") ;;
  esac
done
if ((${#viewers[@]} == 0)); then
  for output in "${connected[@]}"; do
    [[ "$output" == "$settings" ]] || viewers+=("$output")
  done
fi
((${#viewers[@]} > 0)) || die "No RTX viewing output was detected."

main="${PULSAR_PREFERRED_MAIN_OUTPUT:-}"
if [[ -z "$main" ]] || ! is_connected "$main" || [[ "$main" == "$settings" ]]; then
  main=""
  for output in "${viewers[@]}"; do
    if [[ "$output" == DP-* ]]; then main="$output"; break; fi
  done
  [[ -n "$main" ]] || main="${viewers[0]}"
fi

common_mode=""
for candidate in 1920x1080 1280x720; do
  okay=1
  for output in "${viewers[@]}"; do
    supports_mode "$output" "$candidate" || { okay=0; break; }
  done
  if ((okay)); then common_mode="$candidate"; break; fi
done
[[ -n "$common_mode" ]] || die "RTX outputs do not share a common 1920x1080/1280x720 mode."

# Keep the control UI on the small settings display.
xrandr --output "$settings" --auto --pos 0x0 --primary

# A single X11 scanout is rendered on main; every additional RTX output is a
# hardware clone. No extra SDL window or texture upload is created.
if ! xrandr --output "$main" --mode "$common_mode" --rate 60 --right-of "$settings"; then
  xrandr --output "$main" --mode "$common_mode" --right-of "$settings"
fi

for output in "${viewers[@]}"; do
  [[ "$output" == "$main" ]] && continue
  if ! xrandr --output "$output" --mode "$common_mode" --rate 60 --same-as "$main"; then
    xrandr --output "$output" --mode "$common_mode" --same-as "$main"
  fi
done

sleep 0.5
final_state="$(xrandr --query)"
settings_geometry="$(current_geometry "$settings")"
main_geometry="$(current_geometry "$main")"

parse_geometry() {
  local value="$1" fallback_w="$2" fallback_h="$3"
  if [[ "$value" =~ ^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+) ]]; then
    printf '%s %s %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
  else
    printf '%s %s 0 0\n' "$fallback_w" "$fallback_h"
  fi
}

read -r settings_w settings_h settings_x settings_y < <(parse_geometry "$settings_geometry" 1024 600)
read -r main_w main_h main_x main_y < <(parse_geometry "$main_geometry" 1920 1080)

mirror_names=()
for output in "${viewers[@]}"; do
  [[ "$output" == "$main" ]] || mirror_names+=("$output")
done
mirror_csv="$(IFS=,; echo "${mirror_names[*]}")"

mkdir -p "$PULSAR_DATA_DIR"
tmp="$PULSAR_DATA_DIR/displays.env.tmp.$$"
cat >"$tmp" <<ENV
PULSAR_SETTINGS_OUTPUT=$settings
PULSAR_MAIN_OUTPUT=$main
PULSAR_AR_OUTPUT=${mirror_names[0]:-}
PULSAR_AUX_OUTPUTS=
PULSAR_AUX_COUNT=0
PULSAR_AUX_LAYOUT=mirror
PULSAR_SETTINGS_WIDTH=$settings_w
PULSAR_SETTINGS_HEIGHT=$settings_h
PULSAR_SETTINGS_X=$settings_x
PULSAR_SETTINGS_Y=$settings_y
PULSAR_MAIN_WIDTH=$main_w
PULSAR_MAIN_HEIGHT=$main_h
PULSAR_MAIN_X=$main_x
PULSAR_MAIN_Y=$main_y
PULSAR_MAIN_MODE=$common_mode
PULSAR_MAIN_RATE=60
PULSAR_RENDER_MAIN=1
PULSAR_RTX_MIRROR_OUTPUTS=$mirror_csv
ENV
mv -f "$tmp" "$PULSAR_DATA_DIR/displays.env"

log "RTX direct clone: settings=$settings; main=$main; mirrors=${mirror_csv:-none}; mode=$common_mode@60; SDL targets=1"
