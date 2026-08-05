#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
load_config

lock="$PULSAR_DATA_DIR/display-hotplug.lock"
pid="$PULSAR_DATA_DIR/display-hotplug.pid"
interval="${PULSAR_DISPLAY_HOTPLUG_INTERVAL:-1}"
debounce="${PULSAR_DISPLAY_HOTPLUG_DEBOUNCE_SAMPLES:-2}"
mkdir -p "$PULSAR_DATA_DIR"
echo "$$" >"$pid"
exec 9>"$lock"
trap 'rm -f "$pid"' EXIT INT TERM

signature() {
  timeout 5 xrandr --prop 2>/dev/null |
    awk '
      $2=="connected"||$2=="disconnected"{
        print $1,$2
        for(i=3;i<=NF;i++)if($i~/^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+/)print $1,$i
        out=$1;inside=1;edid=0;next
      }
      inside&&/^[^[:space:]]/{inside=0;edid=0}
      inside&&/^[[:space:]]*EDID:/{edid=1;next}
      edid{
        line=$0;gsub(/[[:space:]]/,"",line)
        if(line~/^[0-9a-fA-F]{32}$/)print out,line
        else if(line!="")edid=0
      }
    ' | sha256sum | awk '{print $1}'
}
assigned_inactive() {
  [[ -f "$PULSAR_DATA_DIR/displays.env" ]] || return 1
  local query key out
  query="$(timeout 5 xrandr --query 2>/dev/null || true)"
  while IFS='=' read -r key out; do
    case "$key" in
      PULSAR_SETTINGS_OUTPUT|PULSAR_ROLE_DISPLAY_OUTPUT|PULSAR_ROLE_AR1_OUTPUT|PULSAR_ROLE_AR2_OUTPUT)
        [[ -n "$out" ]] || continue
        awk -v out="$out" '
          $1==out&&$2=="connected"{
            connected=1
            for(i=3;i<=NF;i++)if($i~/^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+/)active=1
          }
          END{exit connected&&!active?0:1}
        ' <<<"$query" && return 0
      ;;
    esac
  done <"$PULSAR_DATA_DIR/displays.env"
  return 1
}

last="$(signature || true)"
candidate=""
stable=0
while :; do
  sleep "$interval"
  current="$(signature || true)"
  repair=0
  if [[ -n "$current" && "$current" != "$last" ]]; then
    if [[ "$current" == "$candidate" ]]; then stable=$((stable+1)); else candidate="$current";stable=1; fi
    ((stable>=debounce)) && repair=1
  else
    candidate="";stable=0
  fi
  assigned_inactive && repair=1
  ((repair==1)) || continue
  flock -n 9 || continue
  if timeout 15 "$PULSAR_ROOT/core/scripts/configure-displays.sh" >>"$PULSAR_LOG_FILE" 2>&1; then
    last="$(signature || true)";candidate="";stable=0
    echo "Pulsar display watch: EDID roles, viewer layout and 7-inch touch refreshed." >>"$PULSAR_LOG_FILE"
  else
    echo "Pulsar display watch: reconfiguration failed; retrying." >>"$PULSAR_LOG_FILE"
  fi
  flock -u 9
done
