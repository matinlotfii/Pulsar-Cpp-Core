#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
load_config

DURATION="${1:-20}"
[[ "$DURATION" =~ ^[0-9]+$ ]] || DURATION=20
((DURATION < 5)) && DURATION=5
APP_LOG="$PULSAR_LOG_FILE"
SAMPLES="/tmp/pulsar-realtime-samples-$$.csv"
WINDOW_LOG="/tmp/pulsar-realtime-window-$$.log"
cleanup() { rm -f "$SAMPLES" "$WINDOW_LOG"; }
trap cleanup EXIT

start_line="$(wc -l <"$APP_LOG" 2>/dev/null || echo 0)"
printf 'epoch,state_ms,cpu_percent,mem_percent,rss_kb,threads,gpu_util,gpu_mem_util,load1\n' >"$SAMPLES"

printf '\n=== 20-SECOND REALTIME OBSERVATION ===\n'
printf 'Started: %s\n' "$(date --iso-8601=seconds)"
printf 'Duration: %ss\n' "$DURATION"
printf '\n--- DISPLAY ROUTING BEFORE ---\n'
cat "$PULSAR_DATA_DIR/displays.env" 2>/dev/null || true
printf '\n--- ACTIVE X11 OUTPUTS BEFORE ---\n'
timeout 4 xrandr --query 2>/dev/null | awk '$2=="connected" {print}' || true
printf '\n--- USB TOPOLOGY ---\n'
lsusb -t 2>/dev/null || true

for _ in $(seq 1 "$DURATION"); do
  epoch="$(date +%s.%N)"
  state_ms="$(curl -sS -o /dev/null --max-time 2 -w '%{time_total}' http://127.0.0.1:4173/api/state 2>/dev/null || echo 9)"
  state_ms="$(awk -v x="$state_ms" 'BEGIN{printf "%.3f", x*1000}')"
  pid="$(cat "$PULSAR_PID_FILE" 2>/dev/null || true)"
  cpu=0 mem=0 rss=0 threads=0
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    read -r cpu mem rss threads < <(ps -p "$pid" -o %cpu=,%mem=,rss=,nlwp= 2>/dev/null | awk '{print $1,$2,$3,$4}')
  fi
  gpu_util=0 gpu_mem_util=0
  if command -v nvidia-smi >/dev/null 2>&1; then
    IFS=, read -r gpu_util gpu_mem_util < <(nvidia-smi --query-gpu=utilization.gpu,utilization.memory --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d ' ' || echo '0,0')
  fi
  load1="$(awk '{print $1}' /proc/loadavg)"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$epoch" "$state_ms" "${cpu:-0}" "${mem:-0}" "${rss:-0}" "${threads:-0}" \
    "${gpu_util:-0}" "${gpu_mem_util:-0}" "${load1:-0}" >>"$SAMPLES"
  sleep 1
done

tail -n "+$((start_line+1))" "$APP_LOG" >"$WINDOW_LOG" 2>/dev/null || true

python3 - "$SAMPLES" "$WINDOW_LOG" <<'PY'
from pathlib import Path
import csv, math, re, statistics, sys
samples_path=Path(sys.argv[1]); log_path=Path(sys.argv[2])

def pct(values,p):
    values=sorted(values)
    if not values: return 0.0
    k=(len(values)-1)*p; lo=math.floor(k); hi=math.ceil(k)
    if lo==hi: return values[lo]
    return values[lo]*(hi-k)+values[hi]*(k-lo)

rows=list(csv.DictReader(samples_path.open()))
print('\n--- SYSTEM/API SAMPLES ---')
for key in ['state_ms','cpu_percent','mem_percent','rss_kb','threads','gpu_util','gpu_mem_util','load1']:
    vals=[]
    for row in rows:
        try: vals.append(float(row[key]))
        except: pass
    if vals:
        print(f'{key}: median={statistics.median(vals):.3f} p95={pct(vals,.95):.3f} max={max(vals):.3f}')

text=log_path.read_text(errors='ignore') if log_path.exists() else ''
patterns={
 'camera_fps':r'(?:Left|Right) Camera: latency-stats.*?output-fps=([0-9.]+)',
 'dequeue_ms':r'(?:Left|Right) Camera: latency-stats.*?dequeue-wait-ms=([0-9.]+)',
 'raw_copy_ms':r'(?:Left|Right) Camera: latency-stats.*?raw-copy-ms=([0-9.]+)',
 'host_pipeline_ms':r'(?:Left|Right) Camera: latency-stats.*?host-pipeline-ms=([0-9.]+)',
 'gpu_h2d_ms':r'(?:Left|Right) Camera: latency-stats.*?gpu-h2d-ms=([0-9.]+)',
 'gpu_total_ms':r'(?:Left|Right) Camera: latency-stats.*?gpu-total-ms=([0-9.]+)',
 'renderer_fps':r'SBS Renderer: latency-stats.*?loop-fps=([0-9.]+)',
 'left_age_ms':r'SBS Renderer: latency-stats.*?left-host-age-ms=([0-9.]+)',
 'right_age_ms':r'SBS Renderer: latency-stats.*?right-host-age-ms=([0-9.]+)',
 'stereo_skew_ms':r'SBS Renderer: latency-stats.*?stereo-host-skew-ms=([0-9.]+)',
 'upload_ms':r'SBS Renderer: latency-stats.*?texture-upload-ms=([0-9.]+)',
 'present_ms':r'SBS Renderer: latency-stats.*?present-ms=([0-9.]+)',
}
print('\n--- CAMERA/RENDER METRICS ---')
metrics={}
for name,pattern in patterns.items():
    vals=[float(x) for x in re.findall(pattern,text)]
    metrics[name]=vals
    if vals:
        print(f'{name}: n={len(vals)} median={statistics.median(vals):.3f} p95={pct(vals,.95):.3f} max={max(vals):.3f}')
    else:
        print(f'{name}: no-samples')

errors=re.findall(r'.*(?:timeout|disconnect|reset|CPU fallback|cuda.*(?:failed|error)|GXImportConfigFile failed).*',text,re.I)
print('\n--- DETECTED EVENTS ---')
print(f'camera_or_cuda_errors={len(errors)}')
for line in errors[-10:]: print(line[:500])

reasons=[]
if metrics['camera_fps'] and statistics.median(metrics['camera_fps']) < 24:
    reasons.append('CAMERA_USB_OR_SENSOR_RATE')
if metrics['raw_copy_ms'] and pct(metrics['raw_copy_ms'],.95) > 14:
    reasons.append('FULL_12MP_HOST_COPY')
if metrics['gpu_h2d_ms'] and pct(metrics['gpu_h2d_ms'],.95) > 8:
    reasons.append('SLOW_OR_PAGEABLE_H2D')
if metrics['present_ms'] and pct(metrics['present_ms'],.95) > 12:
    reasons.append('XORG_SCANOUT_PRESENT_SPIKE')
if metrics['stereo_skew_ms'] and pct(metrics['stereo_skew_ms'],.95) > 20:
    reasons.append('SOFTWARE_STEREO_SKEW')
if any(float(r.get('state_ms','0')) > 100 for r in rows):
    reasons.append('UI_STATE_ENDPOINT_SPIKE')
if errors: reasons.append('CAMERA_OR_CUDA_ERROR_EVENT')
print('\nDIAGNOSIS=' + (','.join(dict.fromkeys(reasons)) if reasons else 'NO_PERIODIC_SOFTWARE_STALL_DETECTED'))
print('PHYSICAL_NOTE=30ms exposure plus approximately 25fps acquisition cannot produce sub-1ms sensor-to-display latency.')
PY

printf '\n--- ACTIVE X11 OUTPUTS AFTER ---\n'
timeout 4 xrandr --query 2>/dev/null | awk '$2=="connected" {print}' || true
printf '\n--- DISPLAY UI STATE SOURCE ---\n'
cat "$PULSAR_DATA_DIR/displays.env" 2>/dev/null || true
printf '\n--- RECENT HOTPLUG/RENDER EVENTS ---\n'
grep -aE 'display hotplug|viewer-layout-ready|live-layout-update|latency-stats|software-start-sync|GPU pipeline ready' "$WINDOW_LOG" | tail -n 80 || true
printf '\nOBSERVATION_STATUS=COMPLETE\n'
