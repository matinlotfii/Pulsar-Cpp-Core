#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/core/scripts/common.sh"
load_config

BASE_URL="http://127.0.0.1:${PULSAR_PORT:-4173}"

DURATION="${1:-${PULSAR_SYSTEM_TRACE_SECONDS:-30}}"
[[ "$DURATION" =~ ^[0-9]+$ ]] || DURATION=30
(( DURATION >= 10 )) || DURATION=10
(( DURATION <= 180 )) || DURATION=180

STAMP="$(date +%Y%m%d-%H%M%S)"
FINAL_DIR="$PULSAR_DATA_DIR/diagnostics"
mkdir -p "$FINAL_DIR"
RAM_PARENT="/dev/shm"
[[ -d "/run/user/$(id -u)" && -w "/run/user/$(id -u)" ]] && RAM_PARENT="/run/user/$(id -u)"
WORK="$RAM_PARENT/pulsar-systemwide-$STAMP-$$"
mkdir -p "$WORK"
SAMPLES="$WORK/cameras.jsonl"
PREVIEW="$WORK/preview-requests.tsv"
SYSTEM="$WORK/system.tsv"
THREADS="$WORK/threads.tsv"
GPU="$WORK/gpu.tsv"
LOG_FILE="${PULSAR_LOG_FILE:-$PULSAR_DATA_DIR/pulsar.log}"
START_BYTES=0
[[ -f "$LOG_FILE" ]] && START_BYTES="$(stat -c '%s' "$LOG_FILE" 2>/dev/null || echo 0)"
START_ISO="$(date --iso-8601=seconds)"
CORE_PID="$(pgrep -n -x pulsar-core || true)"

cleanup() {
  jobs -pr | xargs -r kill 2>/dev/null || true
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

preview_probe() {
  local index="$1" end after=0 header tmp code elapsed bytes frame
  end=$((SECONDS + DURATION)); header="$WORK/preview-$index.headers"; tmp="$WORK/preview-$index.jpg"
  while (( SECONDS < end )); do
    : >"$header"
    read -r code elapsed bytes < <(
      curl -sS --max-time 2 -D "$header" -o "$tmp" \
        -w '%{http_code} %{time_total} %{size_download}\n' \
        "$BASE_URL/camera/$index/frame.jpg?after=$after" || printf '000 2 0\n'
    )
    frame="$(awk 'BEGIN{IGNORECASE=1} /^X-Pulsar-Frame-Id:/ {gsub("\\r", "", $2); print $2}' "$header" | tail -n1)"
    [[ "$frame" =~ ^[0-9]+$ ]] && after="$frame"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s.%N)" "$index" "$code" "$elapsed" "$bytes" "$after" >>"$PREVIEW"
  done
}
preview_probe 0 &
preview_probe 1 &

end=$((SECONDS + DURATION))
while (( SECONDS < end )); do
  now="$(date +%s.%N)"
  printf '%s ' "$now" >>"$SAMPLES"
  curl -fsS --max-time 1 $BASE_URL/api/cameras >>"$SAMPLES" 2>/dev/null || printf '{}' >>"$SAMPLES"
  printf '\n' >>"$SAMPLES"

  read -r load1 load5 load15 _ < /proc/loadavg
  read -r mem_total mem_available swap_total swap_free < <(awk '
    /MemTotal:/ {mt=$2} /MemAvailable:/ {ma=$2} /SwapTotal:/ {st=$2} /SwapFree:/ {sf=$2}
    END {print mt+0,ma+0,st+0,sf+0}' /proc/meminfo)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$load1" "$load5" "$load15" "$mem_total" "$mem_available" "$swap_total" "$swap_free" >>"$SYSTEM"

  if [[ -n "$CORE_PID" && -d "/proc/$CORE_PID" ]]; then
    ps -L -p "$CORE_PID" -o pid,tid,psr,ni,pri,pcpu,pmem,stat,comm --no-headers | sed "s/^/$now /" >>"$THREADS" || true
  fi
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=timestamp,utilization.gpu,utilization.memory,memory.used,memory.total,temperature.gpu,pstate,clocks.current.graphics,power.draw \
      --format=csv,noheader,nounits >>"$GPU" 2>/dev/null || true
  fi
  sleep 1
done
wait

if [[ -f "$LOG_FILE" ]]; then
  tail -c "+$((START_BYTES + 1))" "$LOG_FILE" >"$WORK/application-new.log" 2>/dev/null || true
  tail -n 2500 "$LOG_FILE" >"$WORK/application-tail.log" 2>/dev/null || true
fi
journalctl --no-pager -u pulsar-kiosk.service --since "$START_ISO" >"$WORK/journal-current.txt" 2>/dev/null || true
ps -eo user,pid,ppid,psr,ni,pri,pcpu,pmem,nlwp,stat,etime,cmd >"$WORK/processes.txt"
ps -eLo user,pid,tid,ppid,psr,ni,pri,pcpu,pmem,stat,comm >"$WORK/threads-final.txt"
lsusb -t >"$WORK/usb-topology.txt" 2>/dev/null || true
lsusb >"$WORK/usb-devices.txt" 2>/dev/null || true
xrandr --query >"$WORK/xrandr.txt" 2>/dev/null || true
cp -a "$ROOT/core/config/pulsar.env" "$WORK/" 2>/dev/null || true
cp -a "$ROOT/core/config/pulsar.local.env" "$WORK/" 2>/dev/null || true
cp -a "$PULSAR_DATA_DIR/displays.env" "$WORK/" 2>/dev/null || true
cp -a "$PULSAR_DATA_DIR/display-routing.env" "$WORK/" 2>/dev/null || true

SUMMARY_RAM="$WORK/SUMMARY.txt"
python3 - "$WORK" "$SUMMARY_RAM" "$DURATION" <<'PY'
from __future__ import annotations
import json,re,statistics,sys
from pathlib import Path
work=Path(sys.argv[1]); summary=Path(sys.argv[2]); duration=int(sys.argv[3])

def med(v): return statistics.median(v) if v else None
def p95(v):
    if not v:return None
    x=sorted(v); return x[min(len(x)-1,max(0,int(len(x)*.95)-1))]
def fmt(v): return 'NA' if v is None else f'{v:.3f}'

fps={0:[],1:[]}; online={0:False,1:False}; dims={0:[],1:[]}
for line in (work/'cameras.jsonl').read_text(errors='replace').splitlines():
    try: payload=json.loads(line.split(' ',1)[1])
    except Exception: continue
    for c in payload.get('cameras',[]):
        i=int(c.get('index',-1))
        if i not in fps: continue
        online[i]|=bool(c.get('online'))
        f=c.get('fps'); w=c.get('width'); h=c.get('height')
        if isinstance(f,(int,float)) and f>0:fps[i].append(float(f))
        if isinstance(w,int) and isinstance(h,int):dims[i].append((w,h))

text='\n'.join((work/p).read_text(errors='replace') for p in ('application-tail.log','application-new.log') if (work/p).exists())
patterns={
 'left_output':r'Left Camera: latency-stats.*?output-fps=([0-9.]+)',
 'right_output':r'Right Camera: latency-stats.*?output-fps=([0-9.]+)',
 'left_acquired':r'Left Camera: latency-stats.*?acquired-fps=([0-9.]+)',
 'right_acquired':r'Right Camera: latency-stats.*?acquired-fps=([0-9.]+)',
 'left_dequeue':r'Left Camera: latency-stats.*?dequeue-wait-ms=([0-9.]+)',
 'right_dequeue':r'Right Camera: latency-stats.*?dequeue-wait-ms=([0-9.]+)',
 'left_raw':r'Left Camera: latency-stats.*?raw-copy-ms=([0-9.]+)',
 'right_raw':r'Right Camera: latency-stats.*?raw-copy-ms=([0-9.]+)',
 'left_process':r'Left Camera: latency-stats.*?process-ms=([0-9.]+)',
 'right_process':r'Right Camera: latency-stats.*?process-ms=([0-9.]+)',
 'left_publish':r'Left Camera: latency-stats.*?publish-ms=([0-9.]+)',
 'right_publish':r'Right Camera: latency-stats.*?publish-ms=([0-9.]+)',
 'left_host':r'Left Camera: latency-stats.*?host-pipeline-ms=([0-9.]+)',
 'right_host':r'Right Camera: latency-stats.*?host-pipeline-ms=([0-9.]+)',
 'left_h2d':r'Left Camera: latency-stats.*?gpu-h2d-ms=([0-9.]+)',
 'right_h2d':r'Right Camera: latency-stats.*?gpu-h2d-ms=([0-9.]+)',
 'left_debayer':r'Left Camera: latency-stats.*?gpu-debayer-ms=([0-9.]+)',
 'right_debayer':r'Right Camera: latency-stats.*?gpu-debayer-ms=([0-9.]+)',
 'left_resize':r'Left Camera: latency-stats.*?gpu-resize-ms=([0-9.]+)',
 'right_resize':r'Right Camera: latency-stats.*?gpu-resize-ms=([0-9.]+)',
 'left_d2h':r'Left Camera: latency-stats.*?gpu-d2h-ms=([0-9.]+)',
 'right_d2h':r'Right Camera: latency-stats.*?gpu-d2h-ms=([0-9.]+)',
 'left_gpu':r'Left Camera: latency-stats.*?gpu-total-ms=([0-9.]+)',
 'right_gpu':r'Right Camera: latency-stats.*?gpu-total-ms=([0-9.]+)',
 'renderer_fps':r'SBS Renderer: latency-stats.*?loop-fps=([0-9.]+)',
 'left_age':r'SBS Renderer: latency-stats.*?left-host-age-ms=([0-9.]+)',
 'right_age':r'SBS Renderer: latency-stats.*?right-host-age-ms=([0-9.]+)',
 'skew':r'SBS Renderer: latency-stats.*?stereo-host-skew-ms=([0-9.]+)',
 'upload':r'SBS Renderer: latency-stats.*?texture-upload-ms=([0-9.]+)',
 'present':r'SBS Renderer: latency-stats.*?present-ms=([0-9.]+)',
 'preview_left_fps':r'Left Camera: preview-stats.*?fps=([0-9.]+)',
 'preview_right_fps':r'Right Camera: preview-stats.*?fps=([0-9.]+)',
 'preview_left_resize':r'Left Camera: preview-stats.*?resize-ms=([0-9.]+)',
 'preview_right_resize':r'Right Camera: preview-stats.*?resize-ms=([0-9.]+)',
 'preview_left_jpeg':r'Left Camera: preview-stats.*?jpeg-ms=([0-9.]+)',
 'preview_right_jpeg':r'Right Camera: preview-stats.*?jpeg-ms=([0-9.]+)',
 'preview_left_total':r'Left Camera: preview-stats.*?total-ms=([0-9.]+)',
 'preview_right_total':r'Right Camera: preview-stats.*?total-ms=([0-9.]+)',
 'snapshot_left_request':r'UI Snapshot: latest-stats camera=0.*?request-ms=([0-9.]+)',
 'snapshot_right_request':r'UI Snapshot: latest-stats camera=1.*?request-ms=([0-9.]+)',
 'snapshot_left_age':r'UI Snapshot: latest-stats camera=0.*?source-age-ms=([0-9.]+)',
 'snapshot_right_age':r'UI Snapshot: latest-stats camera=1.*?source-age-ms=([0-9.]+)',
}
vals={k:[] for k in patterns}
for line in text.splitlines():
    for k,p in patterns.items():
        m=re.search(p,line)
        if m: vals[k].append(float(m.group(1)))
metrics={k:med(v[-20:]) for k,v in vals.items()}

req={0:[],1:[]}; req_bytes={0:[],1:[]}; req_ok={0:0,1:0}; frame_ids={0:set(),1:set()}
if (work/'preview-requests.tsv').exists():
  for line in (work/'preview-requests.tsv').read_text(errors='replace').splitlines():
    p=line.split('\t')
    if len(p)!=6:continue
    try:i=int(p[1]);code=p[2];elapsed=float(p[3])*1000;size=int(float(p[4]));fid=int(p[5])
    except Exception:continue
    if i in req:
      req[i].append(elapsed);req_bytes[i].append(size);frame_ids[i].add(fid)
      if code=='200' and size>0:req_ok[i]+=1

gpu_util=[]; gpu_mem=[]; gpu_temp=[]
if (work/'gpu.tsv').exists():
  for line in (work/'gpu.tsv').read_text(errors='replace').splitlines():
    p=[x.strip() for x in line.split(',')]
    try: gpu_util.append(float(p[1]));gpu_mem.append(float(p[3]));gpu_temp.append(float(p[5]))
    except Exception:pass

core_cpu=[]; thread_cpu={}
if (work/'threads.tsv').exists():
  for line in (work/'threads.tsv').read_text(errors='replace').splitlines():
    p=line.split()
    if len(p)<10:continue
    try: cpu=float(p[7]); name=p[-1]
    except Exception:continue
    core_cpu.append(cpu); thread_cpu.setdefault(name,[]).append(cpu)

problems=[]
def problem(stage,detail):problems.append((stage,detail))
lf,rf=med(fps[0]),med(fps[1])
if lf is None or rf is None or min(lf,rf)<29:problem('CAMERA_ACQUISITION',f'API FPS left={fmt(lf)} right={fmt(rf)}; expected >=29 at full sensor')
if max([x for x in (metrics['left_raw'],metrics['right_raw']) if x is not None] or [0])>3:problem('RAW_STAGING_COPY',f'raw-copy left={fmt(metrics["left_raw"])} right={fmt(metrics["right_raw"])} ms')
if max([x for x in (metrics['left_h2d'],metrics['right_h2d']) if x is not None] or [0])>3:problem('CUDA_H2D',f'H2D left={fmt(metrics["left_h2d"])} right={fmt(metrics["right_h2d"])} ms')
if max([x for x in (metrics['left_publish'],metrics['right_publish']) if x is not None] or [0])>4:problem('FRAME_PUBLISH_COPY',f'publish left={fmt(metrics["left_publish"])} right={fmt(metrics["right_publish"])} ms')
if metrics['upload'] is not None and metrics['upload']>6:problem('OPENGL_TEXTURE_UPLOAD',f'texture upload={fmt(metrics["upload"])} ms')
if metrics['present'] is not None and metrics['present']>3:problem('DISPLAY_PRESENT',f'present={fmt(metrics["present"])} ms')
if max([x for x in (metrics['left_age'],metrics['right_age']) if x is not None] or [0])>50:problem('END_TO_END_FRAME_AGE',f'left={fmt(metrics["left_age"])} right={fmt(metrics["right_age"])} ms')
if metrics['skew'] is not None and metrics['skew']>12:problem('STEREO_PAIRING',f'skew={fmt(metrics["skew"])} ms')
if min(req_ok.values())<3 or min(len(x) for x in frame_ids.values())<3:problem('UI_PREVIEW_DELIVERY',f'valid responses left={req_ok[0]} right={req_ok[1]}, unique frames={len(frame_ids[0])}/{len(frame_ids[1])}')
if max([x for x in (metrics['preview_left_total'],metrics['preview_right_total']) if x is not None] or [0])>60:problem('UI_JPEG_PIPELINE',f'preview total left={fmt(metrics["preview_left_total"])} right={fmt(metrics["preview_right_total"])} ms')

out=[]
out += ['PULSAR SYSTEMWIDE LOW-OVERHEAD TRACE','====================================',f'DURATION_SECONDS={duration}',f'CAMERAS_ONLINE={online}',f'CAMERA_API_FPS_MEDIAN={fmt(lf)},{fmt(rf)}',f'CAMERA_API_MODE={statistics.mode(dims[0]) if dims[0] else None},{statistics.mode(dims[1]) if dims[1] else None}','']
out.append('PIPELINE_MEDIANS_MS')
for k in patterns:out.append(f'{k.upper()}={fmt(metrics[k])}')
out += ['', 'UI_LATEST_ONLY_PREVIEW']
for i in (0,1):out.append(f'CAMERA_{i}: responses={req_ok[i]} unique_frames={len(frame_ids[i])} request_median_ms={fmt(med(req[i]))} request_p95_ms={fmt(p95(req[i]))} jpeg_bytes={fmt(med(req_bytes[i]))}')
out += ['', 'SYSTEM_LOAD',f'GPU_UTIL_MEDIAN_PERCENT={fmt(med(gpu_util))}',f'GPU_MEMORY_MEDIAN_MIB={fmt(med(gpu_mem))}',f'GPU_TEMP_MEDIAN_C={fmt(med(gpu_temp))}',f'PULSAR_THREAD_SAMPLE_CPU_MEDIAN={fmt(med(core_cpu))}']
for name,v in sorted(thread_cpu.items(),key=lambda kv:med(kv[1]) or 0,reverse=True)[:12]:out.append(f'THREAD_{name}_CPU_MEDIAN={fmt(med(v))}')
out += ['', 'AUTOMATIC_DIAGNOSIS']
if problems:
  for stage,detail in problems:out.append(f'FAIL {stage}: {detail}')
else:out.append('PASS: No measured software stage crossed the low-latency thresholds.')
out += ['', 'INTERPRETATION_ORDER','1. CAMERA_ACQUISITION/dequeue limits delivered FPS before software processing.','2. RAW_STAGING_COPY and CUDA_H2D identify host-memory transfer cost.','3. GPU debayer/resize/D2H identify CUDA processing cost.','4. FRAME_PUBLISH_COPY identifies the shared RGB handoff cost.','5. OPENGL_TEXTURE_UPLOAD and DISPLAY_PRESENT identify monitor/glasses display cost.','6. UI preview metrics are isolated and cannot queue frames; each request asks only for a frame newer than the last displayed ID.']
summary.write_text('\n'.join(out)+'\n')
PY

SUMMARY_FINAL="$FINAL_DIR/pulsar-systemwide-$STAMP-SUMMARY.txt"
ARCHIVE_FINAL="$FINAL_DIR/pulsar-systemwide-$STAMP.tar.gz"
cp "$SUMMARY_RAM" "$SUMMARY_FINAL"
tar -C "$WORK" -czf "$ARCHIVE_FINAL" .
cat "$SUMMARY_FINAL"
echo "ARCHIVE=$ARCHIVE_FINAL"
echo "SUMMARY=$SUMMARY_FINAL"
