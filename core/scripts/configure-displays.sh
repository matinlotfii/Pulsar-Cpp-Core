#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/common.sh"
load_config

command -v xrandr >/dev/null 2>&1 ||
  die "xrandr is not installed."

mkdir -p "$PULSAR_DATA_DIR"

state=""
props=""
declare -a connected_outputs=()
declare -A edid_cache=()

refresh_state() {
  state="$(timeout 5 xrandr --query)"
  props="$(timeout 5 xrandr --prop 2>/dev/null || true)"

  mapfile -t connected_outputs < <(
    awk '$2 == "connected" {print $1}' <<<"$state" |
      sort -V
  )
}

contains() {
  local wanted="$1" item
  shift || true

  for item in "$@"; do
    [[ "$item" == "$wanted" ]] && return 0
  done

  return 1
}

is_connected() {
  contains "$1" "${connected_outputs[@]}"
}

supports_mode() {
  local output="$1"
  local wanted="$2"

  awk -v output="$output" -v wanted="$wanted" '
    $1 == output && $2 == "connected" {
      inside = 1
      next
    }

    inside && /^[^[:space:]]/ {
      exit
    }

    inside && $1 == wanted {
      found = 1
      exit
    }

    END {
      exit found ? 0 : 1
    }
  ' <<<"$state"
}

preferred_mode() {
  local output="$1"

  awk -v output="$output" '
    $1 == output && $2 == "connected" {
      inside = 1
      next
    }

    inside && /^[^[:space:]]/ {
      inside = 0
    }

    inside && $1 ~ /^[0-9]+x[0-9]+$/ {
      if ($0 ~ /\+/) {
        print $1
        exit
      }

      if (fallback == "") {
        fallback = $1
      }
    }

    END {
      if (fallback != "") {
        print fallback
      }
    }
  ' <<<"$state" |
    head -n1
}

mode_dimensions() {
  local mode="$1"

  if [[ "$mode" =~ ^([0-9]+)x([0-9]+)$ ]]; then
    printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf '1920 1080\n'
  fi
}

output_rates() {
  local output="$1"
  local mode="$2"

  awk -v output="$output" -v wanted="$mode" '
    function clean(value) {
      gsub(/[^0-9.]/, "", value)
      return value
    }

    $1 == output && $2 == "connected" {
      inside = 1
      next
    }

    inside && /^[^[:space:]]/ {
      exit
    }

    inside && $1 == wanted {
      for (i = 2; i <= NF; i++) {
        value = clean($i)

        if (value ~ /^[0-9]+([.][0-9]+)?$/) {
          print value
        }
      }

      exit
    }
  ' <<<"$state"
}

rate_supported() {
  local output="$1"
  local mode="$2"
  local wanted="$3"

  output_rates "$output" "$mode" |
    awk -v wanted="$wanted" '
      function abs(value) {
        return value < 0 ? -value : value
      }

      abs(($1 + 0) - (wanted + 0)) < 0.20 {
        found = 1
      }

      END {
        exit found ? 0 : 1
      }
    '
}

choose_rate() {
  local output="$1"
  local mode="$2"
  local role="$3"
  local requested candidate maximum

  case "$role" in
    ui)
      requested="${PULSAR_SETTINGS_RATE:-59.82}"
      candidates=(59.82 60)
      maximum=75.20
      ;;

    display)
      requested="${PULSAR_MAIN_RATE:-70}"
      candidates=(70 75 60)
      maximum=75.20
      ;;

    ar-glass-*)
      # Air 2 Pro stereo input uses 90 Hz. Do not force 120 Hz for SBS.
      requested="${PULSAR_AR_RATE:-90}"
      candidates=(90 60)
      maximum=90.20
      ;;
  esac

  if [[ -n "$requested" ]] &&
     rate_supported "$output" "$mode" "$requested"; then
    printf '%s\n' "$requested"
    return 0
  fi

  for candidate in "${candidates[@]}"; do
    if rate_supported "$output" "$mode" "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  output_rates "$output" "$mode" |
    awk -v maximum="$maximum" '
      $1 >= 50 && $1 <= maximum {
        print
      }
    ' |
    sort -nr |
    head -n1
}

edid_hex() {
  local output="$1"

  awk -v output="$output" '
    $1 == output && $2 == "connected" {
      inside = 1
      next
    }

    inside && /^[^[:space:]]/ {
      exit
    }

    inside && /^[[:space:]]*EDID:/ {
      edid = 1
      next
    }

    edid {
      line = $0
      gsub(/[[:space:]]/, "", line)

      if (line ~ /^[0-9a-fA-F]{32}$/) {
        printf "%s", line
        next
      }

      if (line != "") {
        exit
      }
    }
  ' <<<"$props"
}

edid_text() {
  local output="$1"
  local hex text

  if [[ -n "${edid_cache[$output]+x}" ]]; then
    printf '%s\n' "${edid_cache[$output]}"
    return 0
  fi

  hex="$(edid_hex "$output")"

  if [[ -z "$hex" ]]; then
    edid_cache["$output"]=""
    return 0
  fi

  text="$(
    python3 - "$hex" <<'PY'
import sys

try:
    data = bytes.fromhex(sys.argv[1])
except ValueError:
    print("")
    raise SystemExit(0)

names = []

for base in range(0, len(data), 128):
    block = data[base:base + 128]

    for offset in (54, 72, 90, 108):
        descriptor = block[offset:offset + 18]

        if len(descriptor) < 18:
            continue

        if descriptor[:5] in (
            b"\x00\x00\x00\xfc\x00",
            b"\x00\x00\x00\xff\x00",
        ):
            value = (
                descriptor[5:18]
                .decode("ascii", "ignore")
                .replace("\x00", "")
                .strip()
            )

            if value:
                names.append(value)

print(" ".join(names))
PY
  )"

  edid_cache["$output"]="$text"
  printf '%s\n' "$text"
}

is_xreal_edid() {
  local text

  text="$(edid_text "$1" | tr '[:upper:]' '[:lower:]')"

  [[ "$text" =~ xreal|nreal|air[[:space:]_-]*2[[:space:]_-]*pro|air[[:space:]_-]*2 ]]
}

safe_usb_id() {
  local device="$1"
  local vendor product

  vendor="$(cat "$device/idVendor" 2>/dev/null || true)"
  product="$(cat "$device/idProduct" 2>/dev/null || true)"

  [[ -n "$vendor" && -n "$product" ]] || return 1
  printf '%s:%s\n' "${vendor,,}" "${product,,}"
}

xreal_usb_count() {
  local device id count=0

  for device in /sys/bus/usb/devices/*; do
    id="$(safe_usb_id "$device" || true)"

    case "$id" in
      3318:0432|3318:0424|3318:0425)
        count=$((count + 1))
        ;;
    esac
  done

  ((count > 2)) && count=2
  printf '%s\n' "$count"
}

high_refresh_output() {
  local output="$1"
  local mode

  mode="$(preferred_mode "$output")"
  [[ -n "$mode" ]] || return 1

  output_rates "$output" "$mode" |
    awk '
      $1 >= 89 && $1 <= 121 {
        found = 1
      }

      END {
        exit found ? 0 : 1
      }
    '
}

choose_largest() {
  local output mode width height area
  local best=""
  local maximum=-1

  for output in "$@"; do
    mode="$(preferred_mode "$output")"
    read -r width height < <(mode_dimensions "$mode")
    area=$((width * height))

    if ((area > maximum)); then
      maximum="$area"
      best="$output"
    fi
  done

  printf '%s\n' "$best"
}

previous_role() {
  local key="$1"

  [[ -f "$PULSAR_DATA_DIR/display-routing.env" ]] || return 0

  sed -n "s/^${key}=//p" \
    "$PULSAR_DATA_DIR/display-routing.env" |
    head -n1
}

append_unique() {
  local array_name="$1"
  local value="$2"
  local existing
  local -n target="$array_name"

  [[ -n "$value" ]] || return 0

  for existing in "${target[@]}"; do
    [[ "$existing" == "$value" ]] && return 0
  done

  target+=("$value")
}

remove_values() {
  local source_name="$1"
  local removed_name="$2"
  local value
  local -n source="$source_name"
  local -n removed="$removed_name"
  local -a filtered=()

  for value in "${source[@]}"; do
    contains "$value" "${removed[@]}" || filtered+=("$value")
  done

  source=("${filtered[@]}")
}

# Wait briefly for NVIDIA PRIME connectors and complete EDID data.
for _ in $(seq 1 20); do
  refresh_state

  ((${#connected_outputs[@]} > 0)) || {
    sleep 0.25
    continue
  }

  incomplete=0

  for output in "${connected_outputs[@]}"; do
    [[ -n "$(preferred_mode "$output")" ]] || incomplete=1
  done

  ((incomplete == 0)) && break
  sleep 0.25
done

((${#connected_outputs[@]} > 0)) ||
  die "No connected X11 display was detected."

# The 7-inch UI is fixed to HDMI-2 whenever available.
settings="${PULSAR_PREFERRED_SETTINGS_OUTPUT:-HDMI-2}"

if ! is_connected "$settings"; then
  settings=""
  smallest=999999999

  for output in "${connected_outputs[@]}"; do
    mode="$(preferred_mode "$output")"
    read -r width height < <(mode_dimensions "$mode")
    area=$((width * height))

    if ((area < smallest)); then
      smallest="$area"
      settings="$output"
    fi
  done
fi

declare -a detected_glasses=()
declare -a remaining_outputs=()

for output in "${connected_outputs[@]}"; do
  [[ "$output" == "$settings" ]] && continue

  if is_xreal_edid "$output"; then
    detected_glasses+=("$output")
  else
    remaining_outputs+=("$output")
  fi
done

# Keep connector assignment stable while hot-plugging a second identical pair.
declare -a glasses=()
previous_ar1="$(previous_role PULSAR_ROLE_AR1_OUTPUT)"
previous_ar2="$(previous_role PULSAR_ROLE_AR2_OUTPUT)"

if contains "$previous_ar1" "${detected_glasses[@]}"; then
  append_unique glasses "$previous_ar1"
fi

if contains "$previous_ar2" "${detected_glasses[@]}"; then
  append_unique glasses "$previous_ar2"
fi

for output in "${detected_glasses[@]}"; do
  append_unique glasses "$output"
done

# Some DP adapters hide the EDID name. Count attached XREAL USB devices and
# promote additional 90/120-Hz outputs until two glasses are assigned.
target_glasses="$(xreal_usb_count)"
((target_glasses < ${#glasses[@]})) &&
  target_glasses="${#glasses[@]}"
((target_glasses > 2)) &&
  target_glasses=2

if ((${#glasses[@]} < target_glasses)); then
  for output in "${remaining_outputs[@]}"; do
    [[ "$output" == "${PULSAR_PREFERRED_MAIN_OUTPUT:-}" ]] && continue

    if high_refresh_output "$output"; then
      append_unique glasses "$output"
    fi

    ((${#glasses[@]} >= target_glasses)) && break
  done
fi

remove_values remaining_outputs glasses

display=""
preferred_display="${PULSAR_PREFERRED_MAIN_OUTPUT:-}"

if [[ -n "$preferred_display" ]] &&
   contains "$preferred_display" "${remaining_outputs[@]}"; then
  display="$preferred_display"
elif ((${#remaining_outputs[@]} > 0)); then
  display="$(choose_largest "${remaining_outputs[@]}")"
fi

# Explicit fallbacks are accepted only for XREAL-like/high-refresh connectors.
for variable in PULSAR_PREFERRED_AR_OUTPUT PULSAR_PREFERRED_AR2_OUTPUT; do
  ((${#glasses[@]} >= 2)) && break

  candidate="${!variable:-}"

  [[ -n "$candidate" ]] || continue
  is_connected "$candidate" || continue
  [[ "$candidate" != "$settings" && "$candidate" != "$display" ]] || continue

  if is_xreal_edid "$candidate" || high_refresh_output "$candidate"; then
    append_unique glasses "$candidate"
  fi
done

ar1="${glasses[0]:-}"
ar2="${glasses[1]:-}"

settings_mode="${PULSAR_SETTINGS_MODE:-1024x600}"

if ! supports_mode "$settings" "$settings_mode"; then
  settings_mode="$(preferred_mode "$settings")"
fi

[[ -n "$settings_mode" ]] ||
  die "No usable mode exists for the UI output '$settings'."

read -r settings_width settings_height < <(
  mode_dimensions "$settings_mode"
)

settings_rate="$(choose_rate "$settings" "$settings_mode" ui || true)"

roles=(display ar-glass-1 ar-glass-2)
connectors=("$display" "$ar1" "$ar2")
modes=("" "" "")
widths=(0 0 0)
heights=(0 0 0)
rates=("" "" "")
flags=(0 0 0)
physical_modes=(none none none)
positions=(none none none)
input_layouts=(none none none)

for index in 0 1 2; do
  output="${connectors[$index]}"

  [[ -n "$output" ]] || continue
  is_connected "$output" || continue

  role="${roles[$index]}"

  if [[ "$role" == "display" ]]; then
    requested="${PULSAR_MAIN_MODE:-1920x1080}"

    if supports_mode "$output" "$requested"; then
      mode="$requested"
    else
      mode="$(preferred_mode "$output")"
    fi

    input_layouts[$index]="2d"
  else
    # Prefer full-SBS only when the glasses EDID actually advertises it.
    full_sbs="${PULSAR_AR_FULL_SBS_MODE:-3840x1080}"
    half_sbs="${PULSAR_AR_MODE:-1920x1080}"

    if supports_mode "$output" "$full_sbs"; then
      mode="$full_sbs"
      input_layouts[$index]="full-sbs"
    elif supports_mode "$output" "$half_sbs"; then
      mode="$half_sbs"
      input_layouts[$index]="half-sbs"
    else
      mode="$(preferred_mode "$output")"
      read -r fallback_width _ < <(mode_dimensions "$mode")

      if ((fallback_width >= 3840)); then
        input_layouts[$index]="full-sbs"
      else
        input_layouts[$index]="half-sbs"
      fi
    fi
  fi

  [[ -n "$mode" ]] || continue

  read -r width height < <(mode_dimensions "$mode")

  modes[$index]="$mode"
  widths[$index]="$width"
  heights[$index]="$height"
  rates[$index]="$(choose_rate "$output" "$mode" "$role" || true)"
done

settings_args=(
  --output "$settings"
  --mode "$settings_mode"
  --pos 0x0
  --primary
  --rotate normal
  --scale 1x1
)

[[ -n "$settings_rate" ]] &&
  settings_args+=(--rate "$settings_rate")

if ! xrandr "${settings_args[@]}"; then
  xrandr \
    --output "$settings" \
    --mode "$settings_mode" \
    --pos 0x0 \
    --primary \
    --rotate normal \
    --scale 1x1
fi

canvas_width=0
canvas_height=1

for index in 0 1 2; do
  [[ -n "${modes[$index]}" ]] || continue

  canvas_width=$((canvas_width + widths[index]))

  if ((heights[index] > canvas_height)); then
    canvas_height="${heights[$index]}"
  fi
done

((canvas_width > 0)) || canvas_width=1

canvas_x="$settings_width"
cursor="$canvas_x"
framebuffer_width=$((canvas_x + canvas_width))
framebuffer_height=$((settings_height > canvas_height ? settings_height : canvas_height))

xrandr \
  --fb "${framebuffer_width}x${framebuffer_height}" \
  2>/dev/null || true

active_outputs=()
active_glasses=()
panel_specs=()

for index in 0 1 2; do
  output="${connectors[$index]}"
  mode="${modes[$index]}"

  [[ -n "$output" && -n "$mode" ]] || continue

  args=(
    --output "$output"
    --mode "$mode"
    --pos "${cursor}x0"
    --rotate normal
    --scale 1x1
  )

  [[ -n "${rates[$index]}" ]] &&
    args+=(--rate "${rates[$index]}")

  if xrandr "${args[@]}" ||
     xrandr \
       --output "$output" \
       --mode "$mode" \
       --pos "${cursor}x0" \
       --rotate normal \
       --scale 1x1; then

    flags[$index]=1
    physical_modes[$index]="$mode"
    positions[$index]="${cursor}x0"

    panel_specs+=(
      "${index}:${widths[$index]}x${heights[$index]}+$((cursor - canvas_x))+0"
    )

    active_outputs+=("$output")

    if ((index > 0)); then
      active_glasses+=("$output")
    fi

    cursor=$((cursor + widths[index]))
  else
    warn "Could not activate ${roles[$index]} on '$output'."
  fi
done

assigned_outputs=("$settings" "${active_outputs[@]}")

for output in "${connected_outputs[@]}"; do
  if ! contains "$output" "${assigned_outputs[@]}"; then
    xrandr --output "$output" --off 2>/dev/null || true
  fi
done

live_width=$((cursor - canvas_x))
((live_width > 0)) || live_width=1

live_height=1

for index in 0 1 2; do
  if [[ "${flags[$index]}" == "1" ]] &&
     ((heights[index] > live_height)); then
    live_height="${heights[$index]}"
  fi
done

final_framebuffer_height=$((settings_height > live_height ? settings_height : live_height))

xrandr \
  --fb "$((canvas_x + live_width))x${final_framebuffer_height}" \
  2>/dev/null || true

active_csv="$(IFS=,; printf '%s' "${active_outputs[*]}")"
glasses_csv="$(IFS=,; printf '%s' "${active_glasses[*]}")"
connector_csv="$(IFS=,; printf '%s' "${connectors[*]}")"
panel_raw="$(IFS=';'; printf '%s' "${panel_specs[*]}")"

printf -v panel_shell '%q' "$panel_raw"

generation="$(date +%s%N)"
display_name=""
ar1_name=""
ar2_name=""

[[ -n "$display" ]] &&
  display_name="$(edid_text "$display" 2>/dev/null || true)"

[[ -n "$ar1" ]] &&
  ar1_name="$(edid_text "$ar1" 2>/dev/null || true)"

[[ -n "$ar2" ]] &&
  ar2_name="$(edid_text "$ar2" 2>/dev/null || true)"

printf -v display_name_shell '%q' "$display_name"
printf -v ar1_name_shell '%q' "$ar1_name"
printf -v ar2_name_shell '%q' "$ar2_name"

layout_tmp="$PULSAR_DATA_DIR/viewer-layout.env.tmp.$$"

cat >"$layout_tmp" <<ENV
PULSAR_VIEWER_LAYOUT_GENERATION=$generation
PULSAR_VIEWER_CANVAS_GEOMETRY=${live_width}x${live_height}+${canvas_x}+0
PULSAR_VIEWER_PANEL_SPECS=$panel_raw
PULSAR_VIEWER_PROFILE_COUNT=3
ENV

mv -f "$layout_tmp" "$PULSAR_DATA_DIR/viewer-layout.env"

routing_tmp="$PULSAR_DATA_DIR/display-routing.env.tmp.$$"

cat >"$routing_tmp" <<ENV
PULSAR_ROLE_UI_OUTPUT=$settings
PULSAR_ROLE_DISPLAY_OUTPUT=$display
PULSAR_ROLE_AR1_OUTPUT=$ar1
PULSAR_ROLE_AR2_OUTPUT=$ar2
ENV

mv -f "$routing_tmp" "$PULSAR_DATA_DIR/display-routing.env"

env_tmp="$PULSAR_DATA_DIR/displays.env.tmp.$$"

cat >"$env_tmp" <<ENV
PULSAR_SETTINGS_OUTPUT=$settings
PULSAR_SETTINGS_WIDTH=$settings_width
PULSAR_SETTINGS_HEIGHT=$settings_height
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
PULSAR_ROLE_DISPLAY_PHYSICAL_MODE=${physical_modes[0]}
PULSAR_ROLE_AR1_PHYSICAL_MODE=${physical_modes[1]}
PULSAR_ROLE_AR2_PHYSICAL_MODE=${physical_modes[2]}
PULSAR_ROLE_DISPLAY_RATE=${rates[0]:-off}
PULSAR_ROLE_AR1_RATE=${rates[1]:-off}
PULSAR_ROLE_AR2_RATE=${rates[2]:-off}
PULSAR_ROLE_DISPLAY_POSITION=${positions[0]}
PULSAR_ROLE_AR1_POSITION=${positions[1]}
PULSAR_ROLE_AR2_POSITION=${positions[2]}
PULSAR_ROLE_DISPLAY_EDID=$display_name_shell
PULSAR_ROLE_AR1_EDID=$ar1_name_shell
PULSAR_ROLE_AR2_EDID=$ar2_name_shell
PULSAR_ROLE_AR1_INPUT_LAYOUT=${input_layouts[1]}
PULSAR_ROLE_AR2_INPUT_LAYOUT=${input_layouts[2]}
PULSAR_VIEWER_OUTPUTS_BY_PROFILE=$connector_csv
PULSAR_VIEWER_ACTIVE_OUTPUTS=$active_csv
PULSAR_VIEWER_ACTIVE_COUNT=${#active_outputs[@]}
PULSAR_VIEWER_CANVAS_X=$canvas_x
PULSAR_VIEWER_CANVAS_Y=0
PULSAR_VIEWER_CANVAS_WIDTH=$live_width
PULSAR_VIEWER_CANVAS_HEIGHT=$live_height
PULSAR_VIEWER_CANVAS_GEOMETRY=${live_width}x${live_height}+${canvas_x}+0
PULSAR_VIEWER_PANEL_SPECS=$panel_shell
PULSAR_AUX_OUTPUTS=$glasses_csv
PULSAR_AUX_COUNT=${#active_glasses[@]}
PULSAR_AUX_LAYOUT=extend
PULSAR_RTX_VIEWER_OUTPUTS=$active_csv
PULSAR_RTX_VIEWER_COUNT=${#active_outputs[@]}
PULSAR_RTX_MIRROR_OUTPUTS=
PULSAR_RTX_MIRROR_COUNT=0
ENV

mv -f "$env_tmp" "$PULSAR_DATA_DIR/displays.env"

log \
  "Dynamic display routing: UI=$settings monitor=${display:-none}[$display_name] glass1=${ar1:-none}[$ar1_name ${modes[1]:-off}@${rates[1]:-off} ${input_layouts[1]}] glass2=${ar2:-none}[$ar2_name ${modes[2]:-off}@${rates[2]:-off} ${input_layouts[2]}] active=${active_csv:-none} canvas=${live_width}x${live_height}+${canvas_x}+0"

timeout 5 \
  "$PULSAR_ROOT/core/scripts/configure-touch.sh" \
  >>"$PULSAR_DATA_DIR/touch.log" 2>&1 || true
