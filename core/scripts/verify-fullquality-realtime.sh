#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/core/scripts/common.sh"
load_config

BASE_URL="http://127.0.0.1:${PULSAR_PORT:-4173}"

DATA_DIR="${PULSAR_DATA_DIR:-$ROOT/core/data}"
LOG_FILE="${PULSAR_LOG_FILE:-$DATA_DIR/pulsar.log}"
REPORT_DIR="$DATA_DIR/latency-reports"
mkdir -p "$REPORT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$REPORT_DIR/verify-fullquality-realtime-$STAMP.txt"
SAMPLES="$REPORT_DIR/verify-fullquality-realtime-$STAMP.samples.jsonl"
PREVIEW="$REPORT_DIR/verify-fullquality-realtime-$STAMP.preview.tsv"
TEST_SECONDS="${PULSAR_VERIFY_SECONDS:-18}"
MIN_FPS="${PULSAR_VERIFY_MIN_FPS:-29.0}"
MAX_SKEW_MS="${PULSAR_VERIFY_MAX_STEREO_SKEW_MS:-12.0}"
MAX_AGE_MS="${PULSAR_VERIFY_MAX_HOST_AGE_MS:-50.0}"

cleanup() {
  jobs -pr | xargs -r kill 2>/dev/null || true
  rm -f "$SAMPLES" "$PREVIEW"
}
trap cleanup EXIT

ready=0
for _ in $(seq 1 120); do
  json="$(curl -fsS --max-time 1 $BASE_URL/api/cameras 2>/dev/null || true)"
  online="$(printf '%s' "$json" | grep -o '"online":true' | wc -l || true)"
  if [[ "$online" -ge 2 ]]; then ready=1; break; fi
  sleep 0.25
done
if [[ "$ready" != 1 ]]; then
  printf '%s\n' 'FULLQUALITY_REALTIME_STATUS=FAIL' 'ERROR=both cameras did not become online' | tee "$REPORT"
  exit 1
fi

log_start_bytes=0
[[ -f "$LOG_FILE" ]] && log_start_bytes="$(stat -c '%s' "$LOG_FILE" 2>/dev/null || echo 0)"

preview_probe() {
  local index="$1" end after=0 header tmp code elapsed bytes frame
  end=$((SECONDS + TEST_SECONDS))
  header="$(mktemp)"
  tmp="$(mktemp)"
  while (( SECONDS < end )); do
    : >"$header"
    read -r code elapsed bytes < <(
      curl -sS --max-time 2 -D "$header" -o "$tmp" \
        -w '%{http_code} %{time_total} %{size_download}\n' \
        "$BASE_URL/camera/$index/frame.jpg?after=$after" || printf '000 2 0\n'
    )
    frame="$(awk 'BEGIN{IGNORECASE=1} /^X-Pulsar-Frame-Id:/ {gsub("\\r", "", $2); print $2}' "$header" | tail -n1)"
    [[ "$frame" =~ ^[0-9]+$ ]] && after="$frame"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s.%N)" "$index" "$code" "$elapsed" "$bytes" >>"$PREVIEW"
  done
  rm -f "$header" "$tmp"
}

preview_probe 0 &
preview_probe 1 &

for _ in $(seq 1 $((TEST_SECONDS * 4))); do
  curl -fsS --max-time 1 $BASE_URL/api/cameras >>"$SAMPLES" 2>/dev/null || printf '{}' >>"$SAMPLES"
  printf '\n' >>"$SAMPLES"
  sleep 0.25
done
wait

DISPLAY_API_OK=0
ROUTING_FILE="$ROOT/core/data/display-routing.env"
if [[ -f "$ROUTING_FILE" ]]; then
  current_ui="$(sed -n 's/^PULSAR_ROLE_UI_OUTPUT=//p' "$ROUTING_FILE" | head -n1)"
  if [[ -n "$current_ui" ]]; then
    payload="$(python3 - "$current_ui" <<'PYJSON'
import json, sys
print(json.dumps({'connector': sys.argv[1], 'role': 'ui'}))
PYJSON
)"
    if curl -fsS --max-time 25 -X POST -H 'Content-Type: application/json' \
        --data "$payload" $BASE_URL/api/system/display-routing >/dev/null; then
      DISPLAY_API_OK=1
    fi
  fi
fi

python3 - "$SAMPLES" "$PREVIEW" "$LOG_FILE" "$ROOT" "$MIN_FPS" "$MAX_SKEW_MS" "$MAX_AGE_MS" "$DISPLAY_API_OK" "$log_start_bytes" >"$REPORT" <<'PY'
from __future__ import annotations
import json, re, statistics, sys
from pathlib import Path

samples_path, preview_path, log_path, root = map(Path, sys.argv[1:5])
min_fps, max_skew, max_age = map(float, sys.argv[5:8])
display_api_ok = sys.argv[8] == '1'
log_start_bytes = int(sys.argv[9])

def median(values):
    return statistics.median(values) if values else None

def fmt(value):
    return 'NA' if value is None else f'{value:.3f}'

fps={0:[],1:[]}; dims={0:[],1:[]}; online={0:False,1:False}
for line in samples_path.read_text(errors='replace').splitlines():
    try: payload=json.loads(line)
    except Exception: continue
    for cam in payload.get('cameras',[]):
        i=int(cam.get('index',-1))
        if i not in fps: continue
        online[i] = online[i] or bool(cam.get('online'))
        value=cam.get('fps')
        if isinstance(value,(int,float)) and value>0: fps[i].append(float(value))
        w,h=cam.get('width'),cam.get('height')
        if isinstance(w,int) and isinstance(h,int): dims[i].append((w,h))

text=''
if log_path.exists():
    raw=log_path.read_bytes()
    # Include current-test bytes plus enough startup context to prove the sensor profile.
    text=(raw[max(0, min(log_start_bytes, len(raw))-250000):]).decode(errors='replace')
lines=text.splitlines()
patterns={
 'left_output':r'Left Camera: latency-stats.*?output-fps=([0-9.]+)',
 'right_output':r'Right Camera: latency-stats.*?output-fps=([0-9.]+)',
 'left_dequeue':r'Left Camera: latency-stats.*?dequeue-wait-ms=([0-9.]+)',
 'right_dequeue':r'Right Camera: latency-stats.*?dequeue-wait-ms=([0-9.]+)',
 'left_raw':r'Left Camera: latency-stats.*?raw-copy-ms=([0-9.]+)',
 'right_raw':r'Right Camera: latency-stats.*?raw-copy-ms=([0-9.]+)',
 'left_process':r'Left Camera: latency-stats.*?process-ms=([0-9.]+)',
 'right_process':r'Right Camera: latency-stats.*?process-ms=([0-9.]+)',
 'left_publish':r'Left Camera: latency-stats.*?publish-ms=([0-9.]+)',
 'right_publish':r'Right Camera: latency-stats.*?publish-ms=([0-9.]+)',
 'left_h2d':r'Left Camera: latency-stats.*?gpu-h2d-ms=([0-9.]+)',
 'right_h2d':r'Right Camera: latency-stats.*?gpu-h2d-ms=([0-9.]+)',
 'left_gpu':r'Left Camera: latency-stats.*?gpu-total-ms=([0-9.]+)',
 'right_gpu':r'Right Camera: latency-stats.*?gpu-total-ms=([0-9.]+)',
 'left_age':r'SBS Renderer: latency-stats.*?left-host-age-ms=([0-9.]+)',
 'right_age':r'SBS Renderer: latency-stats.*?right-host-age-ms=([0-9.]+)',
 'skew':r'SBS Renderer: latency-stats.*?stereo-host-skew-ms=([0-9.]+)',
 'upload':r'SBS Renderer: latency-stats.*?texture-upload-ms=([0-9.]+)',
 'present':r'SBS Renderer: latency-stats.*?present-ms=([0-9.]+)',
 'preview_left_fps':r'Left Camera: preview-stats.*?fps=([0-9.]+)',
 'preview_right_fps':r'Right Camera: preview-stats.*?fps=([0-9.]+)',
 'preview_left_total':r'Left Camera: preview-stats.*?total-ms=([0-9.]+)',
 'preview_right_total':r'Right Camera: preview-stats.*?total-ms=([0-9.]+)',
}
values={k:[] for k in patterns}
for line in lines:
    for key, pattern in patterns.items():
        m=re.search(pattern,line)
        if m: values[key].append(float(m.group(1)))
metrics={k:median(v[-12:]) for k,v in values.items()}

configured={}
for side,w,h in re.findall(r'(Left|Right) Camera: configured sensor=([0-9]+)x([0-9]+)',text):
    configured[side]=(int(w),int(h))

preview={0:[],1:[]}; preview_bytes={0:[],1:[]}; preview_ok={0:0,1:0}
for line in preview_path.read_text(errors='replace').splitlines():
    parts=line.split('\t')
    if len(parts)!=5: continue
    try:
        i=int(parts[1]); code=parts[2]; elapsed=float(parts[3]); size=int(float(parts[4]))
    except Exception: continue
    if i in preview:
        preview[i].append(elapsed*1000.0); preview_bytes[i].append(size)
        if code=='200' and size>0: preview_ok[i]+=1

api_l,api_r=median(fps[0]),median(fps[1])
mode_l=statistics.mode(dims[0]) if dims[0] else None
mode_r=statistics.mode(dims[1]) if dims[1] else None
core_count=0
try:
    import subprocess
    core_count=int(subprocess.check_output(['pgrep','-xc','pulsar-core'],text=True).strip() or '0')
except Exception: pass

config=(root/'core/config/pulsar.env').read_text(errors='replace')
configure_script=root/'core/scripts/configure-displays.sh'
script_text=configure_script.read_text(errors='replace') if configure_script.exists() else ''
routing=root/'core/data/display-routing.env'
display_script_ok=all(t in script_text for t in ('previous_role','PULSAR_ROLE_UI_OUTPUT','PULSAR_VIEWER_PANEL_SPECS'))
routing_ok=routing.exists() and 'PULSAR_ROLE_UI_OUTPUT=' in routing.read_text(errors='replace')
preview_config_ok=all(t in config for t in ('PULSAR_PREVIEW_FPS=12','PULSAR_PREVIEW_MAX_WIDTH=640','PULSAR_PREVIEW_MAX_HEIGHT=360','PULSAR_JPEG_QUALITY=50'))

checks=[]
def check(name,ok,detail): checks.append((name,bool(ok),detail))
check('SINGLE_CORE',core_count==1,f'count={core_count}')
check('CAMERAS_ONLINE',online[0] and online[1],f'left={online[0]} right={online[1]}')
check('FULL_SENSOR_PROFILE',configured.get('Left')==(4024,3036) and configured.get('Right')==(4024,3036),f'{configured}')
check('DISPLAY_FRAME_QUALITY',mode_l and mode_r and min(mode_l[0],mode_r[0])>=1400 and min(mode_l[1],mode_r[1])>=1000,f'left={mode_l} right={mode_r}')
check('CAMERA_FPS',api_l is not None and api_r is not None and api_l>=min_fps and api_r>=min_fps,f'left={fmt(api_l)} right={fmt(api_r)} minimum={min_fps:.1f}')
check('STEREO_SKEW',metrics['skew'] is not None and metrics['skew']<=max_skew,f'median_ms={fmt(metrics["skew"])} maximum={max_skew:.1f}')
check('FRAME_AGE',metrics['left_age'] is not None and metrics['right_age'] is not None and max(metrics['left_age'],metrics['right_age'])<=max_age,f'left_ms={fmt(metrics["left_age"])} right_ms={fmt(metrics["right_age"])} maximum={max_age:.1f}')
check('RAW_COPY',metrics['left_raw'] is not None and metrics['right_raw'] is not None and max(metrics['left_raw'],metrics['right_raw'])<=3.0,f'left_ms={fmt(metrics["left_raw"])} right_ms={fmt(metrics["right_raw"])}')
check('CUDA_H2D',metrics['left_h2d'] is not None and metrics['right_h2d'] is not None and max(metrics['left_h2d'],metrics['right_h2d'])<=3.0,f'left_ms={fmt(metrics["left_h2d"])} right_ms={fmt(metrics["right_h2d"])}')
check('PUBLISH_COPY',metrics['left_publish'] is not None and metrics['right_publish'] is not None and max(metrics['left_publish'],metrics['right_publish'])<=4.0,f'left_ms={fmt(metrics["left_publish"])} right_ms={fmt(metrics["right_publish"])}')
check('TEXTURE_UPLOAD',metrics['upload'] is not None and metrics['upload']<=6.0,f'median_ms={fmt(metrics["upload"])}')
check('PRESENT',metrics['present'] is not None and metrics['present']<=3.0,f'median_ms={fmt(metrics["present"])}')
check('UI_PREVIEW_CONFIG',preview_config_ok,'640x360, 12 fps, JPEG quality 50')
check('UI_LATEST_ONLY_ENDPOINTS',preview_ok[0]>=3 and preview_ok[1]>=3,f'left_responses={preview_ok[0]} right_responses={preview_ok[1]} left_request_ms={fmt(median(preview[0]))} right_request_ms={fmt(median(preview[1]))}')
check('UI_PREVIEW_WORKER', (root/'ui/frontend/src/app/cameraFrameWorker.ts').exists() and 'latest-only live camera preview' in (root/'ui/frontend/src/app/camera-stream.tsx').read_text(errors='replace'),'worker decode + canvas + long poll')
check('DISPLAY_SETTINGS_SCRIPT',display_script_ok,f'path={configure_script}')
check('DISPLAY_ROUTING_STATE',routing_ok,f'path={routing}')
check('DISPLAY_ROUTING_API',display_api_ok,'POST current UI role')

print('PULSAR FULL-QUALITY REALTIME VERIFICATION')
print('========================================')
print(f'CAMERA_API_FPS_MEDIAN={fmt(api_l)},{fmt(api_r)}')
print(f'DISPLAY_FRAME_MODE={mode_l},{mode_r}')
print(f'SENSOR_MODE={configured}')
for key,value in metrics.items(): print(f'{key.upper()}={fmt(value)}')
print(f'PREVIEW_REQUEST_MS={fmt(median(preview[0]))},{fmt(median(preview[1]))}')
print(f'PREVIEW_BYTES={fmt(median(preview_bytes[0]))},{fmt(median(preview_bytes[1]))}')
print('')
failed=[]
for name,ok,detail in checks:
    print(f'{name}={"PASS" if ok else "FAIL"} {detail}')
    if not ok: failed.append(name)
print('')
print('FULLQUALITY_REALTIME_STATUS=' + ('PASS' if not failed else 'FAIL'))
if failed:
    print('FAILED_CHECKS='+','.join(failed))
    raise SystemExit(1)
PY

cat "$REPORT"
echo "REPORT=$REPORT"
