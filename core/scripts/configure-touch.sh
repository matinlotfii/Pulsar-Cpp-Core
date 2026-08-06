#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
load_config

watch=0
attempts=1
interval=1
last_signature=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch) watch=1; attempts=0 ;;
    --attempts) attempts="${2:?missing attempts}"; shift ;;
    --interval) interval="${2:?missing interval}"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

command -v xinput >/dev/null 2>&1 || exit 0
command -v xrandr >/dev/null 2>&1 || exit 0

settings_output() {
  local value="${PULSAR_PREFERRED_SETTINGS_OUTPUT:-HDMI-2}" key
  if [[ -f "$PULSAR_DATA_DIR/displays.env" ]]; then
    while IFS='=' read -r key v; do
      [[ "$key" == "PULSAR_SETTINGS_OUTPUT" ]] && value="$v"
    done <"$PULSAR_DATA_DIR/displays.env"
  fi
  printf '%s\n' "$value"
}
find_touch_devices() {
  if [[ -n "${PULSAR_TOUCH_DEVICE_NAME:-}" ]]; then
    xinput --list --name-only | awk -v target="$PULSAR_TOUCH_DEVICE_NAME" '$0==target{print}'
    return
  fi
  xinput --list --name-only |
    grep -Eiv 'virtual core|xwayland|keyboard|mouse|trackpad|touchpad' |
    grep -Ei 'touch|touchscreen|USB2IIC_CTP_CONTROL|wch\.cn|ctp|goodix|elan|eeti|ilitek|wave|hid.*touch' || true
}
bootloader_present() {
  local d
  for d in /sys/bus/usb/devices/*; do
    [[ -r "$d/idVendor" && -r "$d/idProduct" ]] || continue
    [[ "$(<"$d/idVendor"):$("<$d/idProduct")" == "4348:55e0" ]] && return 0
  done
  return 1
}
matrix_for_output() {
  local target="$1" query
  query="$(xrandr --query 2>/dev/null)" || return 1
  awk -v target="$target" '
    /^Screen 0:/{
      for(i=1;i<=NF;i++)if($i=="current"){
        sw=$(i+1);sh=$(i+3);gsub(/,/,"",sw);gsub(/,/,"",sh)
      }
    }
    $1==target && $2=="connected"{
      for(i=3;i<=NF;i++)if($i~/^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+/){
        split($i,p,"+");split(p[1],s,"x");ow=s[1];oh=s[2];ox=p[2];oy=p[3]
      }
    }
    END{
      if(sw<=0||sh<=0||ow<=0||oh<=0)exit 1
      printf "%.9f 0 %.9f 0 %.9f %.9f 0 0 1\n",ow/sw,ox/sw,oh/sh,oy/sh
    }
  ' <<<"$query"
}
signature() {
  { xrandr --query 2>/dev/null | awk '/^Screen 0:/{print}$2=="connected"{print}'
    xinput --list --short 2>/dev/null | grep -Ei 'touch|USB2IIC|wch\.cn' || true
  } | cksum | awk '{print $1 ":" $2}'
}
run_once() {
  local sig target matrix name id
  sig="$(signature)"
  [[ "$sig" == "$last_signature" ]] && return 0
  last_signature="$sig"
  target="$(settings_output)"
  if ! find_touch_devices | grep -q .; then
    bootloader_present &&
      warn "Touch controller is in WCH bootloader mode." ||
      warn "No XInput touchscreen is visible."
    return 0
  fi
  matrix="$(matrix_for_output "$target" || true)"
  [[ -n "$matrix" ]] || { warn "Touch target $target is not active."; return 0; }
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    id="$(xinput list --id-only "$name" 2>/dev/null || true)"
    [[ -n "$id" ]] || continue
    xinput enable "$id" >/dev/null 2>&1 || true
    xinput set-prop "$id" "Coordinate Transformation Matrix" $matrix
    log "Touch '$name' mapped exactly to $target with matrix $matrix"
  done < <(find_touch_devices)
}
if ((watch==1)); then
  n=0
  while :; do
    run_once || true
    n=$((n+1))
    ((attempts>0 && n>=attempts)) && exit 0
    sleep "$interval"
  done
fi
run_once || true
