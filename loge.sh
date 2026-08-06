OUT="$PWD/pulsar-steady-diagnosis-$(date +%Y%m%d-%H%M%S).log"

ssh matin@192.168.1.123 'bash -s' <<'REMOTE' | tee "$OUT"
set -u

ROOT=/home/matin/Pulsar-Cpp-Core
LOG="$ROOT/core/data/pulsar.log"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PID="$(pgrep -n -x pulsar-core || true)"
START="$(systemctl show pulsar-kiosk.service \
  -p ActiveEnterTimestamp --value)"

echo "============================================================"
echo "PULSAR 30-SECOND STEADY-STATE DIAGNOSIS"
echo "PID=$PID"
echo "SERVICE_START=$START"
echo "DATE=$(date --iso-8601=seconds)"
echo "============================================================"

if [[ -z "$PID" ]]; then
  echo "ERROR: pulsar-core is not running"
  exit 1
fi

OFFSET=0
[[ -f "$LOG" ]] && OFFSET="$(stat -c '%s' "$LOG")"

echo
echo "===== ACTIVE CONFIG ====="
grep -hE '^PULSAR_(CAMERA_FPS|CAMERA_EXPOSURE_US|CAMERA_HARDWARE_ROI|CAMERA_LINK_THROUGHPUT_BPS|ACQUISITION_BUFFER_COUNT|STREAM_TRANSFER_SIZE|STREAM_TRANSFER_URB|GPU_PIPELINE|GPU_DIRECT_SDK_H2D|PREVIEW_FPS|PREVIEW_MAX_WIDTH|PREVIEW_MAX_HEIGHT|JPEG_QUALITY|GL_PBO_UPLOAD|SBS_PRESENT_VSYNC|STEREO_PAIRING_MODE)=' \
  "$ROOT/core/config/pulsar.env" \
  "$ROOT/core/config/pulsar.local.env" 2>/dev/null || true

echo
echo "===== DISPLAY TOPOLOGY ====="
DISPLAY=:0 xrandr --query 2>/dev/null || true

echo
echo "===== COLLECTING 30 SECONDS ====="
echo "در این ۳۰ ثانیه تصویر دوربین و UI را حرکت بده."

(
  for _ in $(seq 1 60); do
    curl -fsS --max-time 1 \
      http://127.0.0.1:4173/api/cameras \
      >>"$TMP/cameras.jsonl" 2>/dev/null || echo '{}' >>"$TMP/cameras.jsonl"
    echo >>"$TMP/cameras.jsonl"
    sleep 0.5
  done
) &
CAMERA_SAMPLER=$!

(
  for _ in $(seq 1 30); do
    echo "--- $(date +%s.%N) ---"
    ps -p "$PID" -o pid,psr,ni,pri,pcpu,pmem,nlwp,stat,etime 2>/dev/null
    ps -L -p "$PID" -o tid,psr,pcpu,stat,comm --sort=-pcpu 2>/dev/null |
      head -n 12
    nvidia-smi \
      --query-gpu=utilization.gpu,utilization.memory,memory.used,pstate,clocks.current.graphics,power.draw,temperature.gpu \
      --format=csv,noheader 2>/dev/null || true
    sleep 1
  done
) >"$TMP/system-samples.log" &
SYSTEM_SAMPLER=$!

wait "$CAMERA_SAMPLER"
wait "$SYSTEM_SAMPLER"

if [[ -f "$LOG" ]]; then
  tail -c "+$((OFFSET + 1))" "$LOG" >"$TMP/runtime-new.log"
else
  : >"$TMP/runtime-new.log"
fi

echo
echo "===== AUTOMATIC MEDIAN ANALYSIS ====="

python3 - "$TMP/cameras.jsonl" "$TMP/runtime-new.log" <<'PY'
import json
import re
import statistics
import sys
from pathlib import Path

api_path = Path(sys.argv[1])
log_path = Path(sys.argv[2])

def median(values):
    return statistics.median(values) if values else None

def show(value):
    return "NA" if value is None else f"{value:.3f}"

api_fps = {0: [], 1: []}
api_mode = {0: [], 1: []}

for line in api_path.read_text(errors="replace").splitlines():
    try:
        payload = json.loads(line)
    except Exception:
        continue

    for camera in payload.get("cameras", []):
        index = camera.get("index")
        if index not in api_fps:
            continue

        fps = camera.get("fps")
        if isinstance(fps, (int, float)) and fps > 0:
            api_fps[index].append(float(fps))

        width = camera.get("width")
        height = camera.get("height")
        if isinstance(width, int) and isinstance(height, int):
            api_mode[index].append((width, height))

text = log_path.read_text(errors="replace")
groups = {
    "Left": {},
    "Right": {},
    "Renderer": {},
    "UI Runtime": {},
    "UI Snapshot": {},
}

number = re.compile(r"([A-Za-z0-9_-]+)=(-?[0-9.]+)")

for line in text.splitlines():
    group = None

    if "Left Camera: latency-stats" in line:
        group = "Left"
    elif "Right Camera: latency-stats" in line:
        group = "Right"
    elif "SBS Renderer: latency-stats" in line:
        group = "Renderer"
    elif "UI Runtime: perf-stats" in line:
        group = "UI Runtime"
    elif "UI Snapshot: latest-stats" in line:
        group = "UI Snapshot"

    if group is None:
        continue

    for key, raw in number.findall(line):
        try:
            value = float(raw)
        except ValueError:
            continue
        groups[group].setdefault(key, []).append(value)

print(
    "CAMERA_API_FPS_MEDIAN="
    f"{show(median(api_fps[0]))},{show(median(api_fps[1]))}"
)
print(
    "CAMERA_API_MODE="
    f"{api_mode[0][-1] if api_mode[0] else 'NA'},"
    f"{api_mode[1][-1] if api_mode[1] else 'NA'}"
)

camera_keys = [
    "output-fps",
    "acquired-fps",
    "stale-dropped",
    "dequeue-wait-ms",
    "raw-copy-ms",
    "process-ms",
    "publish-ms",
    "host-pipeline-ms",
    "gpu-h2d-ms",
    "gpu-debayer-ms",
    "gpu-resize-ms",
    "gpu-d2h-ms",
    "gpu-total-ms",
]

renderer_keys = [
    "loop-fps",
    "left-host-age-ms",
    "right-host-age-ms",
    "stereo-host-skew-ms",
    "texture-upload-ms",
    "prepare-ms",
    "render-ms",
    "present-ms",
    "loop-total-ms",
]

ui_keys = [
    "raf-fps",
    "raf-gap-max-ms",
    "long-tasks",
    "state-api-ms",
    "left-request-ms",
    "right-request-ms",
    "left-source-age-ms",
    "right-source-age-ms",
    "left-decode-ms",
    "right-decode-ms",
    "left-draw-ms",
    "right-draw-ms",
    "left-dropped",
    "right-dropped",
]

for group in ("Left", "Right"):
    print(f"\n[{group}]")
    for key in camera_keys:
        print(f"{key}={show(median(groups[group].get(key, [])))}")

print("\n[Renderer]")
for key in renderer_keys:
    print(f"{key}={show(median(groups['Renderer'].get(key, [])))}")

print("\n[UI]")
for key in ui_keys:
    values = (
        groups["UI Runtime"].get(key, [])
        + groups["UI Snapshot"].get(key, [])
    )
    print(f"{key}={show(median(values))}")

print("\n[Detected stream mode]")
modes = re.findall(
    r"low-latency stream-buffer-mode=([A-Za-z]+)",
    text
)
print(modes[-1] if modes else "not logged during test")
PY

echo
echo "===== PROCESS AND GPU SAMPLES ====="
cat "$TMP/system-samples.log"

echo
echo "===== NEW PIPELINE LOGS ====="
grep -aE \
'latency-stats|preview-stats|UI Runtime: perf-stats|UI Snapshot: latest-stats|stream-buffer-mode=|GPU pipeline|viewer-canvas=|error|failed|timeout|offline' \
  "$TMP/runtime-new.log" |
tail -n 300 || true

echo
echo "===== CURRENT SERVICE ERRORS ====="
journalctl --no-pager \
  -u pulsar-kiosk.service \
  --since "$START" |
grep -aEi 'fatal|failed|error|timeout|offline|disconnect|cuda|gx_status' |
tail -n 100 || true

echo
echo "============================================================"
echo "STEADY-STATE DIAGNOSIS FINISHED"
echo "============================================================"
REMOTE

echo
echo "فایل روی سیستم خودت ذخیره شد:"
echo "$OUT"