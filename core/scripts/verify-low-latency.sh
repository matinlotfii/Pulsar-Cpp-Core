#!/usr/bin/env bash
set -u
set -o pipefail

ROOT="${PULSAR_ROOT:-/home/matin/Pulsar-Cpp-Core}"
LOG="$ROOT/core/data/pulsar.log"
SECONDS_TO_SAMPLE="${1:-12}"

export DISPLAY="${DISPLAY:-:0}"
[[ -f /home/matin/.Xauthority ]] &&
  export XAUTHORITY=/home/matin/.Xauthority

echo "Waiting ${SECONDS_TO_SAMPLE}s for stable latency samples..."
sleep "$SECONDS_TO_SAMPLE"

echo
echo "========== HEALTH =========="
curl -fsS --max-time 3 http://127.0.0.1:4173/health || true
echo

echo
echo "========== IMAGE SETTINGS (MUST STAY UNCHANGED) =========="
curl -fsS --max-time 3 http://127.0.0.1:4173/api/cameras || true
echo

echo
echo "========== LOW-LATENCY CONFIG =========="
for file in \
  "$ROOT/core/config/pulsar.env" \
  "$ROOT/core/config/pulsar.local.env"; do

  echo "--- $file"

  grep -E \
    '^(PULSAR_GPU_PIPELINE|PULSAR_GL_PBO_UPLOAD|PULSAR_STEREO_PAIRING_MODE|PULSAR_SBS_PRESENT_VSYNC|PULSAR_RENDER_EVENT_DRIVEN|PULSAR_ACQUISITION_BUFFER_COUNT|PULSAR_BROWSER_NICE|__GL_SYNC_TO_VBLANK|__GL_MaxFramesAllowed|__GL_YIELD|vblank_mode)=' \
    "$file" 2>/dev/null || true
done

echo
echo "========== CAMERA PIPELINE =========="
grep -aE \
  '^(Left|Right) Camera: latency-stats' \
  "$LOG" 2>/dev/null |
tail -n 16

echo
echo "========== RENDERER PIPELINE =========="
grep -aE \
  '^SBS Renderer: (latency-stats|explicit-swap-interval|renderer=|live-layout-update)' \
  "$LOG" 2>/dev/null |
tail -n 20

echo
echo "========== THREAD SCHEDULING =========="
pid="$(pgrep -xo pulsar-core || true)"

if [[ -n "$pid" ]]; then
  ps -L -p "$pid" \
    -o pid,tid,cls,rtprio,ni,pri,psr,pcpu,comm \
    --sort=-pcpu
else
  echo "pulsar-core is not running."
fi

echo
echo "========== GPU =========="
nvidia-smi \
  --query-gpu=name,pstate,utilization.gpu,utilization.memory,memory.used,clocks.current.graphics \
  --format=csv,noheader 2>/dev/null || true

echo
echo "========== DISPLAY =========="
xrandr --query 2>/dev/null |
grep -E '^(HDMI-2|HDMI-1-0|DP-[0-9-]+) connected' || true

echo
echo "========== INTERPRETATION =========="
echo "Exposure is intentionally unchanged. With 30000 us exposure and 32 FPS,"
echo "camera-to-eye latency cannot physically be below 1 ms."
echo "The optimization target is the software path after capture:"
echo "lower publish allocation cost, lower GL upload stalls, no duplicate presents,"
echo "and realtime precedence for acquisition/renderer over JPEG/browser work."
