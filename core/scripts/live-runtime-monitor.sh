#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/common.sh"
load_config

DURATION="${1:-${PULSAR_LIVE_TRACE_SECONDS:-60}}"
SAMPLE_INTERVAL="${PULSAR_LIVE_SAMPLE_INTERVAL:-1}"
SERVICE="${PULSAR_SERVICE_NAME:-pulsar-kiosk.service}"

[[ "$DURATION" =~ ^[0-9]+$ ]] || die "Duration must be an integer number of seconds."
((DURATION >= 10)) || DURATION=10
((DURATION <= 600)) || DURATION=600

journal_pid=""
app_tail_pid=""
browser_tail_pid=""
cleanup() {
  for pid in "$journal_pid" "$app_tail_pid" "$browser_tail_pid"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  for pid in "$journal_pid" "$app_tail_pid" "$browser_tail_pid"; do
    [[ -n "$pid" ]] && wait "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

prefix_file() {
  local prefix="$1" file="$2"
  [[ -f "$file" ]] || { printf '[%s] missing=%s\n' "$prefix" "$file"; return; }
  sed "s/^/[${prefix}] /" "$file"
}

printf '[TRACE] version=observable-realtime-v9 start=%s duration-sec=%s interval-sec=%s host=%s\n' \
  "$(date --iso-8601=seconds)" "$DURATION" "$SAMPLE_INTERVAL" "$(hostname)"
printf '[TRACE] service-active=%s service-enabled=%s\n' \
  "$(systemctl is-active "$SERVICE" 2>/dev/null || true)" \
  "$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)"
printf '[TRACE] core-count=%s core-pids=%s\n' \
  "$(pgrep -xc pulsar-core 2>/dev/null || true)" \
  "$(pgrep -d, -x pulsar-core 2>/dev/null || true)"

prefix_file DISPLAY_ENV "$PULSAR_DATA_DIR/displays.env"
prefix_file VIEWER_LAYOUT "$PULSAR_DATA_DIR/viewer-layout.env"
prefix_file DISPLAY_ROUTING "$PULSAR_DATA_DIR/display-routing.env"

printf '[PROCESS_TREE_BEGIN]\n'
main_pid="$(systemctl show "$SERVICE" -p MainPID --value 2>/dev/null || true)"
if [[ "$main_pid" =~ ^[0-9]+$ ]] && ((main_pid > 0)); then
  pstree -ap "$main_pid" 2>/dev/null | sed 's/^/[PROCESS] /' || true
fi
printf '[PROCESS_TREE_END]\n'

printf '[DISPLAY_PROBE_BEGIN]\n'
DISPLAY="${DISPLAY:-:0}" "$PULSAR_ROOT/core/scripts/verify-viewer-panels.py" 2>&1 | sed 's/^/[DISPLAY_PROBE] /' || true
printf '[DISPLAY_PROBE_END]\n'

# Follow only the current invocation window. journalctl is line-buffered through stdbuf.
(
  timeout --signal=TERM "${DURATION}s" \
    stdbuf -oL -eL journalctl --no-pager -fu "$SERVICE" -n 0 -o cat 2>&1 |
    stdbuf -oL sed 's/^/[JOURNAL] /'
) &
journal_pid=$!

# The native core intentionally writes high-value timing records to pulsar.log
# instead of journald. Stream only new lines from that bounded runtime file.
(
  touch "$PULSAR_LOG_FILE"
  timeout --signal=TERM "${DURATION}s" \
    stdbuf -oL -eL tail -n 0 -F "$PULSAR_LOG_FILE" 2>&1 |
    stdbuf -oL sed 's/^/[APP] /'
) &
app_tail_pid=$!

browser_log="$PULSAR_DATA_DIR/browser.log"
(
  touch "$browser_log"
  timeout --signal=TERM "${DURATION}s" \
    stdbuf -oL -eL tail -n 0 -F "$browser_log" 2>&1 |
    stdbuf -oL sed 's/^/[BROWSER] /'
) &
browser_tail_pid=$!

start_epoch="$(date +%s)"
end_epoch=$((start_epoch + DURATION))
while (( $(date +%s) < end_epoch )); do
  timestamp="$(date --iso-8601=seconds)"
  core_pid="$(pgrep -n -x pulsar-core 2>/dev/null || true)"
  core_stats="missing"
  if [[ "$core_pid" =~ ^[0-9]+$ ]]; then
    core_stats="$(ps -p "$core_pid" -o pid=,psr=,ni=,pri=,pcpu=,pmem=,nlwp=,stat=,etime= 2>/dev/null | xargs || true)"
  fi

  xorg_cpu="$(pgrep -n -x Xorg 2>/dev/null | xargs -r ps -o pcpu= -p 2>/dev/null | xargs || true)"
  chrome_root_cpu="$(ps -eo pcpu=,args= 2>/dev/null | awk '/\/opt\/google\/chrome\/chrome --kiosk/ && $0 !~ /--type=/ {sum+=$1} END{printf "%.1f",sum+0}')"
  chrome_gpu_cpu="$(ps -eo pcpu=,args= 2>/dev/null | awk '/\/opt\/google\/chrome\/chrome --type=gpu-process/ {sum+=$1} END{printf "%.1f",sum+0}')"
  chrome_renderer_cpu="$(ps -eo pcpu=,args= 2>/dev/null | awk '/\/opt\/google\/chrome\/chrome --type=renderer/ {sum+=$1} END{printf "%.1f",sum+0}')"

  gpu="unavailable"
  if command -v nvidia-smi >/dev/null 2>&1; then
    gpu="$(nvidia-smi --query-gpu=utilization.gpu,utilization.memory,memory.used,memory.total,pstate,clocks.current.graphics,power.draw,temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d ' ' || true)"
  fi

  api="unavailable"
  api_raw="$(curl -fsS --max-time 1 http://127.0.0.1:4173/api/cameras 2>/dev/null || true)"
  if [[ -n "$api_raw" ]]; then
    api="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(";".join(f"{c.get(chr(105)+chr(110)+chr(100)+chr(101)+chr(120))}:{int(bool(c.get(chr(111)+chr(110)+chr(108)+chr(105)+chr(110)+chr(101))))}:{float(c.get(chr(102)+chr(112)+chr(115),0)):.3f}:{c.get(chr(119)+chr(105)+chr(100)+chr(116)+chr(104),0)}x{c.get(chr(104)+chr(101)+chr(105)+chr(103)+chr(104)+chr(116),0)}" for c in d.get("cameras",[])))' <<<"$api_raw" 2>/dev/null || true)"
  fi

  outputs="$(DISPLAY="${DISPLAY:-:0}" xrandr --query 2>/dev/null | awk '$2=="connected" {printf "%s:%s;",$1,($3 ~ /^[0-9]+x[0-9]+/ ? $3 : "inactive")}' || true)"
  loadavg="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || true)"
  memory="$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{if(t>0)printf "%.1f",100*(t-a)/t}' /proc/meminfo 2>/dev/null || true)"

  printf '[SYSTEM] ts=%s core="%s" xorg-cpu=%s chrome-root-cpu=%s chrome-gpu-cpu=%s chrome-renderer-cpu=%s gpu="%s" api="%s" outputs="%s" load="%s" memory-used-pct=%s\n' \
    "$timestamp" "$core_stats" "${xorg_cpu:-0}" "$chrome_root_cpu" "$chrome_gpu_cpu" \
    "$chrome_renderer_cpu" "$gpu" "$api" "$outputs" "$loadavg" "${memory:-0}"
  sleep "$SAMPLE_INTERVAL"
done

wait "$journal_pid" 2>/dev/null || true
wait "$app_tail_pid" 2>/dev/null || true
wait "$browser_tail_pid" 2>/dev/null || true
journal_pid=""
app_tail_pid=""
browser_tail_pid=""
printf '[DISPLAY_PROBE_FINAL_BEGIN]\n'
DISPLAY="${DISPLAY:-:0}" "$PULSAR_ROOT/core/scripts/verify-viewer-panels.py" 2>&1 | sed 's/^/[DISPLAY_PROBE_FINAL] /' || true
printf '[DISPLAY_PROBE_FINAL_END]\n'
printf '[TRACE] end=%s\n' "$(date --iso-8601=seconds)"
