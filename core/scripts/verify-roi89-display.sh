#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/core/scripts/common.sh"
load_config

DATA_DIR="${PULSAR_DATA_DIR:-$ROOT/core/data}"
LOG_FILE="${PULSAR_LOG_FILE:-$DATA_DIR/pulsar.log}"
REPORT_DIR="$DATA_DIR/latency-reports"
mkdir -p "$REPORT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$REPORT_DIR/verify-roi89-display-$STAMP.txt"
SAMPLES="$REPORT_DIR/verify-roi89-display-$STAMP.samples.jsonl"
MIN_FPS="${PULSAR_VERIFY_MIN_FPS:-84.0}"
MAX_SKEW_MS="${PULSAR_VERIFY_MAX_STEREO_SKEW_MS:-12.0}"
MAX_AGE_MS="${PULSAR_VERIFY_MAX_HOST_AGE_MS:-35.0}"

cleanup() { rm -f "$SAMPLES"; }
trap cleanup EXIT

ready=0
for _ in $(seq 1 80); do
  json="$(curl -fsS --max-time 1 http://127.0.0.1:4173/api/cameras 2>/dev/null || true)"
  online="$(printf '%s' "$json" | grep -o '"online":true' | wc -l || true)"
  if [[ "$online" -ge 2 ]]; then ready=1; break; fi
  sleep 0.25
done

if [[ "$ready" != 1 ]]; then
  echo "CAMERA_STATUS=FAIL" | tee "$REPORT"
  echo "ERROR: both cameras did not become online" | tee -a "$REPORT"
  exit 1
fi

for _ in $(seq 1 60); do
  curl -fsS --max-time 1 http://127.0.0.1:4173/api/cameras >>"$SAMPLES" || true
  printf '\n' >>"$SAMPLES"
  sleep 0.25
done

# Prove that the UI display-routing API can save and re-apply the current UI
# connector without changing the user's selected routing.
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
    if curl -fsS --max-time 25 -X POST \
        -H 'Content-Type: application/json' \
        --data "$payload" \
        http://127.0.0.1:4173/api/system/display-routing >/dev/null; then
      DISPLAY_API_OK=1
    fi
  fi
fi

python3 - "$SAMPLES" "$LOG_FILE" "$ROOT" "$MIN_FPS" "$MAX_SKEW_MS" "$MAX_AGE_MS" "$DISPLAY_API_OK" >"$REPORT" <<'PY'
from __future__ import annotations
import json, re, statistics, sys
from pathlib import Path

samples_path = Path(sys.argv[1])
log_path = Path(sys.argv[2])
root = Path(sys.argv[3])
min_fps = float(sys.argv[4])
max_skew = float(sys.argv[5])
max_age = float(sys.argv[6])
display_api_ok = sys.argv[7] == '1'

fps = {0: [], 1: []}
dims = {0: [], 1: []}
online = {0: False, 1: False}
for line in samples_path.read_text(errors='replace').splitlines():
    try:
        payload = json.loads(line)
    except Exception:
        continue
    for camera in payload.get('cameras', []):
        index = int(camera.get('index', -1))
        if index not in fps:
            continue
        online[index] = online[index] or bool(camera.get('online'))
        value = camera.get('fps')
        if isinstance(value, (int, float)) and value > 0:
            fps[index].append(float(value))
        w, h = camera.get('width'), camera.get('height')
        if isinstance(w, int) and isinstance(h, int):
            dims[index].append((w, h))

text = log_path.read_text(errors='replace') if log_path.exists() else ''
lines = text.splitlines()[-4000:]

metric_patterns = {
    'left_output': (r'Left Camera: latency-stats.*?output-fps=([0-9.]+)', []),
    'right_output': (r'Right Camera: latency-stats.*?output-fps=([0-9.]+)', []),
    'left_raw': (r'Left Camera: latency-stats.*?raw-copy-ms=([0-9.]+)', []),
    'right_raw': (r'Right Camera: latency-stats.*?raw-copy-ms=([0-9.]+)', []),
    'left_h2d': (r'Left Camera: latency-stats.*?gpu-h2d-ms=([0-9.]+)', []),
    'right_h2d': (r'Right Camera: latency-stats.*?gpu-h2d-ms=([0-9.]+)', []),
    'left_age': (r'SBS Renderer: latency-stats.*?left-host-age-ms=([0-9.]+)', []),
    'right_age': (r'SBS Renderer: latency-stats.*?right-host-age-ms=([0-9.]+)', []),
    'skew': (r'SBS Renderer: latency-stats.*?stereo-host-skew-ms=([0-9.]+)', []),
    'upload': (r'SBS Renderer: latency-stats.*?texture-upload-ms=([0-9.]+)', []),
    'present': (r'SBS Renderer: latency-stats.*?present-ms=([0-9.]+)', []),
}
for line in lines:
    for key, (pattern, values) in metric_patterns.items():
        match = re.search(pattern, line)
        if match:
            values.append(float(match.group(1)))

def median(values):
    return statistics.median(values[-20:]) if values else None

def fmt(value):
    return 'NA' if value is None else f'{value:.3f}'

api_l = median(fps[0])
api_r = median(fps[1])
mode_l = statistics.mode(dims[0]) if dims[0] else None
mode_r = statistics.mode(dims[1]) if dims[1] else None
metrics = {key: median(values) for key, (_, values) in metric_patterns.items()}

configured = re.findall(r'(Left|Right) Camera: configured sensor=([0-9]+)x([0-9]+)', text)
configured_latest = {}
for side, w, h in configured:
    configured_latest[side] = (int(w), int(h))

configure_script = root / 'core/scripts/configure-displays.sh'
script_text = configure_script.read_text(errors='replace') if configure_script.exists() else ''
routing = root / 'core/data/display-routing.env'
display_script_ok = all(token in script_text for token in (
    'previous_role', 'PULSAR_ROLE_UI_OUTPUT', 'PULSAR_ROLE_AR1_OUTPUT',
    'PULSAR_VIEWER_PANEL_SPECS'))
routing_ok = routing.exists() and 'PULSAR_ROLE_UI_OUTPUT=' in routing.read_text(errors='replace')

checks = []
def check(name, ok, detail):
    checks.append((name, bool(ok), detail))

check('CAMERAS_ONLINE', online[0] and online[1], f'left={online[0]} right={online[1]}')
check('ROI_API', mode_l == (1920,1080) and mode_r == (1920,1080), f'left={mode_l} right={mode_r}')
check('ROI_DEVICE', configured_latest.get('Left') == (1920,1080) and configured_latest.get('Right') == (1920,1080), f'{configured_latest}')
check('FPS', api_l is not None and api_r is not None and api_l >= min_fps and api_r >= min_fps, f'left={fmt(api_l)} right={fmt(api_r)} minimum={min_fps:.1f}')
check('FPS_BALANCE', api_l is not None and api_r is not None and abs(api_l-api_r) <= 4.0, f'delta={fmt(abs(api_l-api_r) if api_l is not None and api_r is not None else None)}')
check('STEREO_SKEW', metrics['skew'] is not None and metrics['skew'] <= max_skew, f'median_ms={fmt(metrics["skew"])} maximum={max_skew:.1f}')
check('FRAME_AGE', metrics['left_age'] is not None and metrics['right_age'] is not None and max(metrics['left_age'],metrics['right_age']) <= max_age, f'left_ms={fmt(metrics["left_age"])} right_ms={fmt(metrics["right_age"])} maximum={max_age:.1f}')
check('RAW_COPY', metrics['left_raw'] is not None and metrics['right_raw'] is not None and max(metrics['left_raw'],metrics['right_raw']) <= 4.0, f'left_ms={fmt(metrics["left_raw"])} right_ms={fmt(metrics["right_raw"])}')
check('CUDA_H2D', metrics['left_h2d'] is not None and metrics['right_h2d'] is not None and max(metrics['left_h2d'],metrics['right_h2d']) <= 4.0, f'left_ms={fmt(metrics["left_h2d"])} right_ms={fmt(metrics["right_h2d"])}')
check('TEXTURE_UPLOAD', metrics['upload'] is not None and metrics['upload'] <= 8.0, f'median_ms={fmt(metrics["upload"])}')
check('DISPLAY_SETTINGS_SCRIPT', display_script_ok, f'path={configure_script}')
check('DISPLAY_ROUTING_STATE', routing_ok, f'path={routing}')
check('DISPLAY_ROUTING_API', display_api_ok, 'POST current UI role through /api/system/display-routing')

print('PULSAR ROI89 + DISPLAY SETTINGS VERIFICATION')
print('============================================')
print(f'CAMERA_API_FPS_MEDIAN={fmt(api_l)},{fmt(api_r)}')
print(f'CAMERA_API_MODE={mode_l},{mode_r}')
for key in metrics:
    print(f'{key.upper()}={fmt(metrics[key])}')
print('')
failed = []
for name, ok, detail in checks:
    print(f'{name}={"PASS" if ok else "FAIL"} {detail}')
    if not ok:
        failed.append(name)
print('')
print('DISPLAY_STATUS=' + ('PASS' if display_script_ok and routing_ok else 'FAIL'))
print('ROI89_STATUS=' + ('PASS' if not failed else 'FAIL'))
if failed:
    print('FAILED_CHECKS=' + ','.join(failed))
    raise SystemExit(1)
PY

cat "$REPORT"
echo "REPORT=$REPORT"
