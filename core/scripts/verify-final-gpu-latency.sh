#!/usr/bin/env bash
set -u
set -o pipefail

ROOT=/home/matin/Pulsar-Cpp-Core
LOG="$ROOT/core/data/pulsar.log"
SECONDS_TO_SAMPLE="${1:-25}"

export DISPLAY=:0
export XAUTHORITY=/home/matin/.Xauthority

start_size="$(stat -c %s "$LOG" 2>/dev/null || echo 0)"
sleep "$SECONDS_TO_SAMPLE"
end_size="$(stat -c %s "$LOG" 2>/dev/null || echo "$start_size")"
window=/tmp/pulsar-final-gpu-latency-window.log

if ((end_size >= start_size)); then
  tail -c "+$((start_size + 1))" "$LOG" >"$window" 2>/dev/null || true
else
  tail -n 5000 "$LOG" >"$window" 2>/dev/null || true
fi

echo "========== HEALTH =========="
curl -fsS --max-time 3 http://127.0.0.1:4173/health
echo
curl -fsS --max-time 3 http://127.0.0.1:4173/api/cameras
echo

echo
echo "========== ACTIVE OUTPUTS =========="
xrandr --query 2>/dev/null | grep -E '^(HDMI-2|HDMI-1-0|DP-[0-9-]+) connected' || true
echo
cat "$ROOT/core/data/display-routing.env" 2>/dev/null || true

echo
echo "========== THREADS =========="
pid="$(pgrep -xo pulsar-core || true)"
if [[ -n "$pid" ]]; then
  ps -L -p "$pid" -o pid,tid,cls,rtprio,ni,pri,psr,pcpu,pmem,stat,comm --sort=-pcpu | head -n 50
fi

echo
echo "========== GPU =========="
nvidia-smi --query-gpu=name,pstate,utilization.gpu,utilization.memory,memory.used,clocks.current.graphics,power.draw --format=csv,noheader 2>/dev/null || true

echo
echo "========== LIVE LATENCY =========="
grep -aE '^(Left|Right) Camera: latency-stats|^SBS Renderer: latency-stats|direct SDK H2D|driver-managed' "$window" | tail -n 100

echo
echo "========== SUMMARY =========="
python3 - "$window" <<'PY_SUMMARY_7281'
import math
import pathlib
import re
import statistics
import sys

text = pathlib.Path(sys.argv[1]).read_text(errors="replace")
camera = [line for line in text.splitlines() if " Camera: latency-stats" in line]
renderer = [line for line in text.splitlines() if "SBS Renderer: latency-stats" in line]
fields = {
    "output_fps": (camera, r"output-fps=([0-9.]+)"),
    "raw_copy_ms": (camera, r"raw-copy-ms=([0-9.]+)"),
    "host_pipeline_ms": (camera, r"host-pipeline-ms=([0-9.]+)"),
    "gpu_h2d_ms": (camera, r"gpu-h2d-ms=([0-9.]+)"),
    "gpu_total_ms": (camera, r"gpu-total-ms=([0-9.]+)"),
    "publish_ms": (camera, r"publish-ms=([0-9.]+)"),
    "left_age_ms": (renderer, r"left-host-age-ms=([0-9.]+)"),
    "right_age_ms": (renderer, r"right-host-age-ms=([0-9.]+)"),
    "stereo_skew_ms": (renderer, r"stereo-host-skew-ms=([0-9.]+)"),
    "upload_ms": (renderer, r"texture-upload-ms=([0-9.]+)"),
    "present_ms": (renderer, r"present-ms=([0-9.]+)"),
    "present_max_ms": (renderer, r"present-max-ms=([0-9.]+)"),
}

def vals(lines, pattern):
    rx = re.compile(pattern)
    return [float(m.group(1)) for line in lines if (m := rx.search(line))]

def p95(data):
    ordered = sorted(data)
    return ordered[min(len(ordered) - 1, math.ceil(len(ordered) * 0.95) - 1)]

print(f"camera_samples={len(camera)}")
print(f"renderer_samples={len(renderer)}")
for name, (lines, pattern) in fields.items():
    data = vals(lines, pattern)
    if data:
        print(f"{name}: median={statistics.median(data):.3f} p95={p95(data):.3f} max={max(data):.3f}")
    else:
        print(f"{name}: no-samples")

print("IMAGE_PROFILE_CHANGED=0")
PY_SUMMARY_7281
