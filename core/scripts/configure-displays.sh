#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_config
command -v xrandr >/dev/null 2>&1 || die "xrandr is not installed."

read_xrandr_state() {
  xrandr --query
}

collect_connected_outputs() {
  local state="$1"
  awk '$2=="connected" {print $1}' <<<"$state"
}

output_exists() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

area_for() {
  local mode="$1" w h
  w="${mode%x*}"
  h="${mode#*x}"
  [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]] || { echo 0; return; }
  echo $((w * h))
}

# Prints: MODE RATE. Prefer the EDID-preferred (+) mode/rate, then the
# currently active (*) mode/rate, then the first progressive mode listed.
mode_and_rate_for() {
  local output="$1"
  awk -v out="$output" '
    function clean_rate(value) {
      gsub(/[^0-9.]/, "", value)
      return value
    }
    function remember(kind, mode, rate) {
      if (mode == "" || rate == "") return
      if (kind == "preferred" && preferred_mode == "") {
        preferred_mode = mode
        preferred_rate = rate
      }
      if (kind == "current" && current_mode == "") {
        current_mode = mode
        current_rate = rate
      }
    }
    $1 == out && $2 == "connected" { inside = 1; next }
    inside && /^[^[:space:]]/ { inside = 0 }
    inside && $1 ~ /^[0-9]+x[0-9]+$/ && $1 !~ /i$/ {
      mode = $1
      if (fallback_mode == "") fallback_mode = mode
      last_rate = ""
      for (i = 2; i <= NF; ++i) {
        token = $i
        if (token ~ /^[0-9.]+[*+]*$/) {
          rate = clean_rate(token)
          if (fallback_rate == "" && mode == fallback_mode) fallback_rate = rate
          last_rate = rate
          if (token ~ /\+/) remember("preferred", mode, rate)
          if (token ~ /\*/) remember("current", mode, rate)
        } else {
          if (token ~ /\+/ && last_rate != "") remember("preferred", mode, last_rate)
          if (token ~ /\*/ && last_rate != "") remember("current", mode, last_rate)
        }
      }
    }
    END {
      if (preferred_mode != "") print preferred_mode, preferred_rate
      else if (current_mode != "") print current_mode, current_rate
      else if (fallback_mode != "") print fallback_mode, fallback_rate
    }
  ' <<<"$xrandr_state"
}

geometry_for() {
  local output="$1"
  awk -v out="$output" '
    $1 == out && $2 == "connected" {
      for (i = 3; i <= NF; ++i) {
        if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+/) {
          print $i
          exit
        }
      }
    }
  ' <<<"$xrandr_state"
}

physical_area_for() {
  local output="$1"
  awk -v out="$output" '
    $1 == out && $2 == "connected" {
      for (i = 3; i <= NF; ++i) {
        if ($i ~ /^[0-9]+mm$/ && (i + 2) <= NF && $(i + 1) == "x" && $(i + 2) ~ /^[0-9]+mm$/) {
          w = $i
          h = $(i + 2)
          gsub(/mm/, "", w)
          gsub(/mm/, "", h)
          print w * h
          exit
        }
      }
      print 0
      exit
    }
  ' <<<"$xrandr_state"
}

mode_supported() {
  local output="$1" requested_mode="$2"
  awk -v out="$output" -v wanted="$requested_mode" '
    $1 == out && $2 == "connected" { inside = 1; next }
    inside && /^[^[:space:]]/ { exit }
    inside && $1 == wanted { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' <<<"$xrandr_state"
}

apply_output_mode() {
  local output="$1" role="$2"
  shift 2
  local position_args=("$@")
  local detected mode rate requested_mode requested_rate

  detected="$(mode_and_rate_for "$output")"
  mode="${detected%% *}"
  rate="${detected#* }"
  [[ "$rate" == "$detected" ]] && rate=""

  if [[ "$role" == "settings" ]]; then
    requested_mode="${PULSAR_SETTINGS_MODE:-}"
    requested_rate="${PULSAR_SETTINGS_RATE:-${PULSAR_PREFERRED_SETTINGS_RATE:-}}"
  else
    requested_mode="${PULSAR_MAIN_MODE:-}"
    requested_rate="${PULSAR_MAIN_RATE:-${PULSAR_PREFERRED_MAIN_RATE:-}}"
  fi

  if [[ -n "$requested_mode" ]]; then
    if mode_supported "$output" "$requested_mode"; then
      mode="$requested_mode"
    else
      warn "$role display $output does not support requested mode $requested_mode; using detected mode $mode."
    fi
  fi
  [[ -n "$requested_rate" ]] && rate="$requested_rate"

  if [[ -n "$mode" && -n "$rate" ]]; then
    if xrandr --output "$output" --mode "$mode" --rate "$rate" "${position_args[@]}"; then
      printf '%s %s\n' "$mode" "$rate"
      return 0
    fi
    warn "Could not set $output to ${mode}@${rate}; retrying without an explicit refresh rate."
  fi

  if [[ -n "$mode" ]] && xrandr --output "$output" --mode "$mode" "${position_args[@]}"; then
    printf '%s %s\n' "$mode" "auto"
    return 0
  fi

  warn "Could not set detected mode on $output; falling back to xrandr --auto."
  xrandr --output "$output" --auto "${position_args[@]}"
  printf '%s %s\n' "auto" "auto"
}

retry_count="${PULSAR_DISPLAY_RETRY_COUNT:-20}"
retry_delay="${PULSAR_DISPLAY_RETRY_DELAY:-1}"
settle_samples="${PULSAR_DISPLAY_SETTLE_SAMPLES:-3}"
preferred_settings_output="${PULSAR_PREFERRED_SETTINGS_OUTPUT:-}"
preferred_main_output="${PULSAR_PREFERRED_MAIN_OUTPUT:-}"
expected_output_count="${PULSAR_EXPECTED_DISPLAY_COUNT:-1}"
[[ "$expected_output_count" =~ ^[1-9][0-9]*$ ]] || expected_output_count=1

# Wait until the connected-output set is stable. This prevents the first display
# that appears during boot from being configured before a second GPU/output is
# ready. Exact connector overrides, when provided, are also respected.
last_signature=""
stable_samples=0
xrandr_state=""
outputs=()
for _ in $(seq 1 "$retry_count"); do
  xrandr_state="$(read_xrandr_state)"
  mapfile -t outputs < <(collect_connected_outputs "$xrandr_state")
  signature="$(printf '%s\n' "${outputs[@]}" | sort | paste -sd, -)"

  found_settings=0
  found_main=0
  [[ -z "$preferred_settings_output" ]] && found_settings=1
  [[ -z "$preferred_main_output" ]] && found_main=1
  output_exists "$preferred_settings_output" "${outputs[@]}" && found_settings=1 || true
  output_exists "$preferred_main_output" "${outputs[@]}" && found_main=1 || true

  if [[ -n "$signature" && "$signature" == "$last_signature" ]]; then
    stable_samples=$((stable_samples + 1))
  else
    stable_samples=0
    last_signature="$signature"
  fi

  if ((${#outputs[@]} >= expected_output_count)) &&
     ((stable_samples >= settle_samples)) &&
     [[ "$found_settings" == "1" && "$found_main" == "1" ]]; then
    break
  fi
  sleep "$retry_delay"
done

# Re-read immediately before role selection. A GPU-backed output may appear
# during the final settle/apply interval after the previous sample was taken.
xrandr_state="$(read_xrandr_state)"
mapfile -t outputs < <(collect_connected_outputs "$xrandr_state")

if ((${#outputs[@]} < expected_output_count)); then
  warn "Expected $expected_output_count connected X11 displays but detected ${#outputs[@]} after ${retry_count}s; continuing with the available display set."
fi

((${#outputs[@]} > 0)) || die "No connected X11 display was detected."

# The settings screen is the connected display with the smallest native mode;
# the SBS screen is the largest remaining display. Physical size is used as a
# tie-breaker. Optional connector-name overrides remain available for machines
# that need a fixed mapping.
if [[ -n "$preferred_settings_output" ]] && output_exists "$preferred_settings_output" "${outputs[@]}"; then
  settings="$preferred_settings_output"
else
  settings="${outputs[0]}"
  min_area=9223372036854775807
  min_physical=9223372036854775807
  for output in "${outputs[@]}"; do
    detected="$(mode_and_rate_for "$output")"
    mode="${detected%% *}"
    area="$(area_for "$mode")"
    physical="$(physical_area_for "$output")"
    ((physical > 0)) || physical=9223372036854775807
    if ((area < min_area || (area == min_area && physical < min_physical))); then
      min_area="$area"
      min_physical="$physical"
      settings="$output"
    fi
  done
fi

if [[ -n "$preferred_main_output" ]] &&
   output_exists "$preferred_main_output" "${outputs[@]}" &&
   [[ "$preferred_main_output" != "$settings" ]]; then
  main="$preferred_main_output"
else
  main="$settings"
  max_area=-1
  max_physical=-1
  if ((${#outputs[@]} >= 2)); then
    for output in "${outputs[@]}"; do
      [[ "$output" == "$settings" ]] && continue
      detected="$(mode_and_rate_for "$output")"
      mode="${detected%% *}"
      area="$(area_for "$mode")"
      physical="$(physical_area_for "$output")"
      if ((area > max_area || (area == max_area && physical > max_physical))); then
        max_area="$area"
        max_physical="$physical"
        main="$output"
      fi
    done
  fi
fi

settings_choice="$(apply_output_mode "$settings" settings --pos 0x0 --primary)"
if ((${#outputs[@]} >= 2)) && [[ "$main" != "$settings" ]]; then
  main_choice="$(apply_output_mode "$main" main --right-of "$settings")"
  render_main=1
else
  main_choice="$settings_choice"
  render_main=0
fi

# Re-read the final X11 geometry only after both outputs have been configured.
sleep "${PULSAR_DISPLAY_APPLY_DELAY:-0.5}"
xrandr_state="$(read_xrandr_state)"

parse_geometry() {
  local geometry="$1" default_width="$2" default_height="$3"
  if [[ "$geometry" =~ ^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$ ]]; then
    printf '%s %s %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
  else
    printf '%s %s 0 0\n' "$default_width" "$default_height"
  fi
}

read -r settings_width settings_height settings_x settings_y < <(
  parse_geometry "$(geometry_for "$settings")" 1024 768
)
read -r main_width main_height main_x main_y < <(
  parse_geometry "$(geometry_for "$main")" "$settings_width" "$settings_height"
)

settings_mode="${settings_choice%% *}"
settings_rate="${settings_choice#* }"
main_mode="${main_choice%% *}"
main_rate="${main_choice#* }"

mkdir -p "$PULSAR_DATA_DIR"
env_tmp="$PULSAR_DATA_DIR/displays.env.tmp.$$"
cat >"$env_tmp" <<ENV
PULSAR_SETTINGS_OUTPUT=$settings
PULSAR_MAIN_OUTPUT=$main
PULSAR_SETTINGS_WIDTH=$settings_width
PULSAR_SETTINGS_HEIGHT=$settings_height
PULSAR_SETTINGS_X=$settings_x
PULSAR_SETTINGS_Y=$settings_y
PULSAR_SETTINGS_MODE=$settings_mode
PULSAR_SETTINGS_RATE=$settings_rate
PULSAR_MAIN_WIDTH=$main_width
PULSAR_MAIN_HEIGHT=$main_height
PULSAR_MAIN_X=$main_x
PULSAR_MAIN_Y=$main_y
PULSAR_MAIN_MODE=$main_mode
PULSAR_MAIN_RATE=$main_rate
PULSAR_RENDER_MAIN=$render_main
ENV
mv -f "$env_tmp" "$PULSAR_DATA_DIR/displays.env"

log "Settings display: $settings ${settings_width}x${settings_height}+${settings_x}+${settings_y} (${settings_mode}@${settings_rate}); SBS display: $main ${main_width}x${main_height}+${main_x}+${main_y} (${main_mode}@${main_rate}); native SBS: $render_main"
