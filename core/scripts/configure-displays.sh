#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
load_config
command -v xrandr >/dev/null 2>&1 || die "xrandr is not installed."
mkdir -p "$PULSAR_DATA_DIR"

state=""
props=""
declare -a all_outputs=()
declare -a connected_outputs=()
declare -A edid_cache=()

refresh_state() {
  state="$(timeout 5 xrandr --query)"
  props="$(timeout 5 xrandr --prop 2>/dev/null || true)"
  mapfile -t all_outputs < <(awk '$2=="connected" || $2=="disconnected"{print $1}' <<<"$state")
  mapfile -t connected_outputs < <(awk '$2=="connected"{print $1}' <<<"$state")
}
contains() {
  local wanted="$1" item
  shift || true
  for item in "$@"; do [[ "$item" == "$wanted" ]] && return 0; done
  return 1
}
is_connected() { contains "$1" "${connected_outputs[@]}"; }

supports_mode() {
  local out="$1" wanted="$2"
  awk -v out="$out" -v wanted="$wanted" '
    $1==out && $2=="connected"{inside=1;next}
    inside && /^[^[:space:]]/{exit}
    inside && $1==wanted{found=1;exit}
    END{exit found?0:1}
  ' <<<"$state"
}
preferred_mode() {
  local out="$1"
  awk -v out="$out" '
    $1==out && $2=="connected"{inside=1;next}
    inside && /^[^[:space:]]/{inside=0}
    inside && $1~/^[0-9]+x[0-9]+$/{
      if($0~/\+/){print $1;exit}
      if(fallback=="")fallback=$1
    }
    END{if(fallback!="")print fallback}
  ' <<<"$state" | head -n1
}
mode_dimensions() {
  [[ "$1" =~ ^([0-9]+)x([0-9]+)$ ]] &&
    printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" ||
    printf '1920 1080\n'
}
output_rates() {
  local out="$1" mode="$2"
  awk -v out="$out" -v mode="$mode" '
    function clean(v){gsub(/[^0-9.]/,"",v);return v}
    $1==out && $2=="connected"{inside=1;next}
    inside && /^[^[:space:]]/{exit}
    inside && $1==mode{
      for(i=2;i<=NF;i++){v=clean($i);if(v~/^[0-9]+([.][0-9]+)?$/)print v}
      exit
    }
  ' <<<"$state"
}
rate_supported() {
  output_rates "$1" "$2" | awk -v wanted="$3" '
    function abs(v){return v<0?-v:v}
    abs(($1+0)-(wanted+0))<0.2{ok=1}
    END{exit ok?0:1}
  '
}
best_rate() {
  local out="$1" mode="$2" role="$3" wanted
  case "$role" in
    ui) wanted="${PULSAR_SETTINGS_RATE:-59.82}" ;;
    display) wanted="${PULSAR_MAIN_RATE:-70}" ;;
    *) wanted="${PULSAR_AR_RATE:-90}" ;;
  esac
  if [[ -n "$wanted" ]] && rate_supported "$out" "$mode" "$wanted"; then
    printf '%s\n' "$wanted"; return
  fi
  case "$role" in
    display) candidates=(70 75 60); max=75.2 ;;
    ar-glass-*) candidates=(90 120 60); max=120.2 ;;
    *) candidates=(60 59.82); max=75.2 ;;
  esac
  for wanted in "${candidates[@]}"; do
    rate_supported "$out" "$mode" "$wanted" && { printf '%s\n' "$wanted"; return; }
  done
  output_rates "$out" "$mode" | awk -v max="$max" '$1>=50&&$1<=max{print}' | sort -nr | head -n1
}
edid_hex() {
  local out="$1"
  awk -v out="$out" '
    $1==out && $2=="connected"{inside=1;next}
    inside && /^[^[:space:]]/{exit}
    inside && /^[[:space:]]*EDID:/{edid=1;next}
    edid{
      line=$0;gsub(/[[:space:]]/,"",line)
      if(line~/^[0-9a-fA-F]{32}$/){printf "%s",line;next}
      if(line!="")exit
    }
  ' <<<"$props"
}
edid_text() {
  local out="$1" hex text
  if [[ -n "${edid_cache[$out]+x}" ]]; then printf '%s\n' "${edid_cache[$out]}"; return; fi
  hex="$(edid_hex "$out")"
  [[ -n "$hex" ]] || { edid_cache["$out"]=""; return; }
  text="$(python3 - "$hex" <<'PY'
import sys
try:
    data = bytes.fromhex(sys.argv[1])
except ValueError:
    print("")
    raise SystemExit
name = ""
for base in range(0, len(data), 128):
    block = data[base:base+128]
    for offset in (54, 72, 90, 108):
        desc = block[offset:offset+18]
        if len(desc) >= 18 and desc[:5] == b"\x00\x00\x00\xfc\x00":
            name = desc[5:18].decode("ascii", "ignore").replace("\x00", "").strip()
            break
    if name:
        break
print(name)
PY
)"
  edid_cache["$out"]="$text"
  printf '%s\n' "$text"
}
xreal_usb_present() {
  local d id
  for d in /sys/bus/usb/devices/*; do
    [[ -r "$d/idVendor" && -r "$d/idProduct" ]] || continue
    id="$(<"$d/idVendor"):$("<$d/idProduct")"
    case "${id,,}" in 3318:0432|3318:0424|3318:0425) return 0;; esac
  done
  return 1
}
is_glasses() {
  local text
  text="$(edid_text "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$text" =~ xreal|nreal|air[[:space:]_-]*2[[:space:]_-]*pro|air[[:space:]_-]*2 ]]
}
high_refresh() {
  local mode
  mode="$(preferred_mode "$1")"; [[ -n "$mode" ]] || mode=1920x1080
  output_rates "$1" "$mode" | awk '$1>=89&&$1<=121{ok=1}END{exit ok?0:1}'
}
choose_largest() {
  local out mode w h area best="" max=-1
  for out in "$@"; do
    mode="$(preferred_mode "$out")"; read -r w h < <(mode_dimensions "$mode")
    area=$((w*h)); ((area>max)) && { max=$area; best="$out"; }
  done
  printf '%s\n' "$best"
}

for _ in $(seq 1 16); do
  refresh_state
  ((${#connected_outputs[@]}>0)) || { sleep .25; continue; }
  incomplete=0
  for out in "${connected_outputs[@]}"; do [[ -n "$(preferred_mode "$out")" ]] || incomplete=1; done
  ((incomplete==0)) && break
  sleep .25
done
((${#connected_outputs[@]}>0)) || die "No connected X11 display was detected."

settings="${PULSAR_PREFERRED_SETTINGS_OUTPUT:-HDMI-2}"
if ! is_connected "$settings"; then
  settings=""; min=999999999
  for out in "${connected_outputs[@]}"; do
    mode="$(preferred_mode "$out")"; read -r w h < <(mode_dimensions "$mode"); area=$((w*h))
    ((area<min)) && { min=$area; settings="$out"; }
  done
fi

glasses=(); normals=()
for out in "${connected_outputs[@]}"; do
  [[ "$out" == "$settings" ]] && continue
  if is_glasses "$out"; then glasses+=("$out"); else normals+=("$out"); fi
done

if ((${#glasses[@]}==0)) && xreal_usb_present; then
  for out in "${normals[@]}"; do
    if high_refresh "$out"; then
      glasses+=("$out"); tmp=()
      for x in "${normals[@]}"; do [[ "$x" == "$out" ]] || tmp+=("$x"); done
      normals=("${tmp[@]}"); break
    fi
  done
fi

display=""
pref="${PULSAR_PREFERRED_MAIN_OUTPUT:-}"
[[ -n "$pref" ]] && contains "$pref" "${normals[@]}" && display="$pref"
if [[ -z "$display" && ${#normals[@]} -gt 0 ]]; then
  display="$(choose_largest "${normals[@]}")"
fi
ar1="${glasses[0]:-}"
ar2="${glasses[1]:-}"

if [[ -z "$ar1" ]]; then
  pref="${PULSAR_PREFERRED_AR_OUTPUT:-}"
  [[ -n "$pref" ]] && is_connected "$pref" && [[ "$pref" != "$settings" && "$pref" != "$display" ]] && ar1="$pref"
fi
if [[ -z "$ar2" ]]; then
  pref="${PULSAR_PREFERRED_AR2_OUTPUT:-}"
  [[ -n "$pref" ]] && is_connected "$pref" && [[ "$pref" != "$settings" && "$pref" != "$display" && "$pref" != "$ar1" ]] && ar2="$pref"
fi

settings_mode="${PULSAR_SETTINGS_MODE:-1024x600}"
supports_mode "$settings" "$settings_mode" || settings_mode="$(preferred_mode "$settings")"
[[ -n "$settings_mode" ]] || die "No mode for UI output $settings"
read -r settings_w settings_h < <(mode_dimensions "$settings_mode")
settings_rate="$(best_rate "$settings" "$settings_mode" ui || true)"

roles=(display ar-glass-1 ar-glass-2)
connectors=("$display" "$ar1" "$ar2")
modes=("" "" ""); widths=(0 0 0); heights=(0 0 0); rates=("" "" "")
flags=(0 0 0); physical=(none none none); positions=(none none none)

for i in 0 1 2; do
  out="${connectors[$i]}"; [[ -n "$out" ]] || continue; is_connected "$out" || continue
  [[ "$i" == 0 ]] && requested="${PULSAR_MAIN_MODE:-1920x1080}" || requested="${PULSAR_AR_MODE:-1920x1080}"
  supports_mode "$out" "$requested" && mode="$requested" || mode="$(preferred_mode "$out")"
  [[ -n "$mode" ]] || continue
  read -r w h < <(mode_dimensions "$mode")
  modes[$i]="$mode"; widths[$i]="$w"; heights[$i]="$h"; rates[$i]="$(best_rate "$out" "$mode" "${roles[$i]}" || true)"
done

args=(--output "$settings" --mode "$settings_mode" --pos 0x0 --primary --rotate normal --scale 1x1)
[[ -n "$settings_rate" ]] && args+=(--rate "$settings_rate")
xrandr "${args[@]}" || xrandr --output "$settings" --mode "$settings_mode" --pos 0x0 --primary --rotate normal --scale 1x1

canvas_w=0; canvas_h=1
for i in 0 1 2; do
  [[ -n "${modes[$i]}" ]] || continue
  canvas_w=$((canvas_w+widths[i])); ((heights[i]>canvas_h)) && canvas_h="${heights[$i]}"
done
((canvas_w>0)) || canvas_w=1
canvas_x="$settings_w"; fb_w=$((canvas_x+canvas_w)); fb_h=$((settings_h>canvas_h?settings_h:canvas_h))
xrandr --fb "${fb_w}x${fb_h}" 2>/dev/null || true

active=(); active_glasses=(); panels=(); cursor="$canvas_x"
for i in 0 1 2; do
  out="${connectors[$i]}"; mode="${modes[$i]}"
  [[ -n "$out" && -n "$mode" ]] || continue
  args=(--output "$out" --mode "$mode" --pos "${cursor}x0" --rotate normal --scale 1x1)
  [[ -n "${rates[$i]}" ]] && args+=(--rate "${rates[$i]}")
  if xrandr "${args[@]}" || xrandr --output "$out" --mode "$mode" --pos "${cursor}x0" --rotate normal --scale 1x1; then
    flags[$i]=1; physical[$i]="$mode"; positions[$i]="${cursor}x0"
    panels+=("${i}:${widths[$i]}x${heights[$i]}+$((cursor-canvas_x))+0")
    active+=("$out"); if ((i>0)); then active_glasses+=("$out"); fi
    cursor=$((cursor+widths[i]))
  else
    warn "Could not activate ${roles[$i]} on $out"
  fi
done

assigned=("$settings" "${active[@]}")
for out in "${connected_outputs[@]}"; do contains "$out" "${assigned[@]}" || xrandr --output "$out" --off 2>/dev/null || true; done
live_w=$((cursor-canvas_x)); ((live_w>0)) || live_w=1
live_h=1
for i in 0 1 2; do [[ "${flags[$i]}" == 1 ]] && ((heights[i]>live_h)) && live_h="${heights[$i]}"; done
xrandr --fb "$((canvas_x+live_w))x$((settings_h>live_h?settings_h:live_h))" 2>/dev/null || true

active_csv="$(IFS=,; echo "${active[*]}")"
glass_csv="$(IFS=,; echo "${active_glasses[*]}")"
connector_csv="$(IFS=,; echo "${connectors[*]}")"
panel_raw="$(IFS=';'; echo "${panels[*]}")"; printf -v panel_shell '%q' "$panel_raw"
generation="$(date +%s%N)"
display_name=""; ar1_name=""; ar2_name=""
[[ -n "$display" ]] && display_name="$(edid_text "$display" 2>/dev/null || true)"
[[ -n "$ar1" ]] && ar1_name="$(edid_text "$ar1" 2>/dev/null || true)"
[[ -n "$ar2" ]] && ar2_name="$(edid_text "$ar2" 2>/dev/null || true)"
printf -v display_name_shell '%q' "$display_name"
printf -v ar1_name_shell '%q' "$ar1_name"
printf -v ar2_name_shell '%q' "$ar2_name"

tmp="$PULSAR_DATA_DIR/viewer-layout.env.tmp.$$"
cat >"$tmp" <<ENV
PULSAR_VIEWER_LAYOUT_GENERATION=$generation
PULSAR_VIEWER_CANVAS_GEOMETRY=${live_w}x${live_h}+${canvas_x}+0
PULSAR_VIEWER_PANEL_SPECS=$panel_raw
PULSAR_VIEWER_PROFILE_COUNT=3
ENV
mv -f "$tmp" "$PULSAR_DATA_DIR/viewer-layout.env"

tmp="$PULSAR_DATA_DIR/display-routing.env.tmp.$$"
cat >"$tmp" <<ENV
PULSAR_ROLE_UI_OUTPUT=$settings
PULSAR_ROLE_DISPLAY_OUTPUT=$display
PULSAR_ROLE_AR1_OUTPUT=$ar1
PULSAR_ROLE_AR2_OUTPUT=$ar2
ENV
mv -f "$tmp" "$PULSAR_DATA_DIR/display-routing.env"

tmp="$PULSAR_DATA_DIR/displays.env.tmp.$$"
cat >"$tmp" <<ENV
PULSAR_SETTINGS_OUTPUT=$settings
PULSAR_SETTINGS_WIDTH=$settings_w
PULSAR_SETTINGS_HEIGHT=$settings_h
PULSAR_SETTINGS_X=0
PULSAR_SETTINGS_Y=0
PULSAR_SETTINGS_MODE=$settings_mode
PULSAR_MAIN_OUTPUT=${display:-${ar1:-${ar2:-}}}
PULSAR_MAIN_WIDTH=${widths[0]}
PULSAR_MAIN_HEIGHT=${heights[0]}
PULSAR_MAIN_X=$canvas_x
PULSAR_MAIN_Y=0
PULSAR_MAIN_MODE=${modes[0]:-none}
PULSAR_RENDER_MAIN=1
PULSAR_ROLE_UI_OUTPUT=$settings
PULSAR_ROLE_DISPLAY_OUTPUT=$display
PULSAR_ROLE_AR1_OUTPUT=$ar1
PULSAR_ROLE_AR2_OUTPUT=$ar2
PULSAR_ROLE_DISPLAY_CONNECTED=${flags[0]}
PULSAR_ROLE_AR1_CONNECTED=${flags[1]}
PULSAR_ROLE_AR2_CONNECTED=${flags[2]}
PULSAR_ROLE_DISPLAY_LOGICAL_MODE=${widths[0]}x${heights[0]}
PULSAR_ROLE_AR1_LOGICAL_MODE=${widths[1]}x${heights[1]}
PULSAR_ROLE_AR2_LOGICAL_MODE=${widths[2]}x${heights[2]}
PULSAR_ROLE_DISPLAY_PHYSICAL_MODE=${physical[0]}
PULSAR_ROLE_AR1_PHYSICAL_MODE=${physical[1]}
PULSAR_ROLE_AR2_PHYSICAL_MODE=${physical[2]}
PULSAR_ROLE_DISPLAY_RATE=${rates[0]:-off}
PULSAR_ROLE_AR1_RATE=${rates[1]:-off}
PULSAR_ROLE_AR2_RATE=${rates[2]:-off}
PULSAR_ROLE_DISPLAY_POSITION=${positions[0]}
PULSAR_ROLE_AR1_POSITION=${positions[1]}
PULSAR_ROLE_AR2_POSITION=${positions[2]}
PULSAR_ROLE_DISPLAY_EDID=$display_name_shell
PULSAR_ROLE_AR1_EDID=$ar1_name_shell
PULSAR_ROLE_AR2_EDID=$ar2_name_shell
PULSAR_VIEWER_OUTPUTS_BY_PROFILE=$connector_csv
PULSAR_VIEWER_ACTIVE_OUTPUTS=$active_csv
PULSAR_VIEWER_ACTIVE_COUNT=${#active[@]}
PULSAR_VIEWER_CANVAS_X=$canvas_x
PULSAR_VIEWER_CANVAS_Y=0
PULSAR_VIEWER_CANVAS_WIDTH=$live_w
PULSAR_VIEWER_CANVAS_HEIGHT=$live_h
PULSAR_VIEWER_CANVAS_GEOMETRY=${live_w}x${live_h}+${canvas_x}+0
PULSAR_VIEWER_PANEL_SPECS=$panel_shell
PULSAR_AUX_OUTPUTS=$glass_csv
PULSAR_AUX_COUNT=${#active_glasses[@]}
PULSAR_AUX_LAYOUT=extend
PULSAR_RTX_VIEWER_OUTPUTS=$active_csv
PULSAR_RTX_VIEWER_COUNT=${#active[@]}
PULSAR_RTX_MIRROR_OUTPUTS=
PULSAR_RTX_MIRROR_COUNT=0
ENV
mv -f "$tmp" "$PULSAR_DATA_DIR/displays.env"

log "Dynamic display routing: UI=$settings monitor=${display:-none}[$display_name] glass1=${ar1:-none}[$ar1_name] active=${active_csv:-none} canvas=${live_w}x${live_h}+${canvas_x}+0"
timeout 5 "$PULSAR_ROOT/core/scripts/configure-touch.sh" >>"$PULSAR_DATA_DIR/touch.log" 2>&1 || true
