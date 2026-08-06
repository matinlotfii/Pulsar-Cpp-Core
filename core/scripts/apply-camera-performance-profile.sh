#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOCAL_ENV="$ROOT/core/config/pulsar.local.env"

# Source defaults are authoritative for the camera/processing pipeline in this
# release. Keep machine-specific display, touch, network and audio settings,
# but remove stale camera overrides left by earlier ROI/binning experiments.
[[ -f "$LOCAL_ENV" ]] || exit 0

backup_dir="$ROOT/.pulsar-backups/camera-runtime"
mkdir -p "$backup_dir"
backup="$backup_dir/pulsar.local.env.$(date +%Y%m%d-%H%M%S).bak"
cp -a "$LOCAL_ENV" "$backup"

python3 - "$LOCAL_ENV" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
managed = {
    "PULSAR_CAMERA_FPS",
    "PULSAR_SYSTEM_TRACE_SECONDS",
    "PULSAR_RENDER_PBO_REUSE",
    "PULSAR_UI_REALTIME_MODE",
    "PULSAR_JPEG_QUALITY",
    "PULSAR_PREVIEW_LOG_INTERVAL_SEC",
    "PULSAR_PREVIEW_MAX_HEIGHT",
    "PULSAR_PREVIEW_MAX_WIDTH",
    "PULSAR_PREVIEW_FPS",
    "PULSAR_CAMERA_MAX_WIDTH",
    "PULSAR_CAMERA_MAX_HEIGHT",
    "PULSAR_CAMERA_SENSOR_SCALE",
    "PULSAR_CAMERA_EXPOSURE_US",
    "PULSAR_CAMERA_GAIN_DB_X10",
    "PULSAR_CAMERA_AUTO_EXPOSURE",
    "PULSAR_CAMERA_PROFILE_ENABLED",
    "PULSAR_CAMERA_PROFILE_VERIFY",
    "PULSAR_CAMERA_PROFILE_REQUIRED",
    "PULSAR_LEFT_CAMERA_PROFILE",
    "PULSAR_RIGHT_CAMERA_PROFILE",
    "PULSAR_CAMERA_HARDWARE_ROI",
    "PULSAR_CAMERA_ROI_REQUIRED",
    "PULSAR_CAMERA_ROI_WIDTH",
    "PULSAR_CAMERA_ROI_HEIGHT",
    "PULSAR_ACQUISITION_BUFFER_COUNT",
    "PULSAR_GPU_PIPELINE",
    "PULSAR_GPU_DIRECT_SDK_H2D",
    "PULSAR_CAMERA_LINK_THROUGHPUT_BPS",
    "PULSAR_STREAM_TRANSFER_SIZE",
    "PULSAR_STREAM_TRANSFER_URB",
    "PULSAR_CAMERA_SYNC_MODE",
    "PULSAR_SOFTWARE_START_SYNC",
    "PULSAR_PARALLEL_STREAM_ON",
    "PULSAR_SOFTWARE_START_SYNC_TIMEOUT_MS",
    "PULSAR_GL_PBO_UPLOAD",
    "PULSAR_STEREO_PAIRING_MODE",
    "PULSAR_SBS_PRESENT_VSYNC",
    "__GL_SYNC_TO_VBLANK",
    "vblank_mode",
}

out = []
removed = []
for line in path.read_text().splitlines():
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or "=" not in stripped:
        out.append(line)
        continue
    key = stripped.split("=", 1)[0].strip()
    if key in managed:
        removed.append(key)
        continue
    out.append(line)

path.write_text("\n".join(out).rstrip() + "\n")
print("[Pulsar] Removed stale local camera overrides: " +
      (", ".join(sorted(set(removed))) if removed else "none"))
PY

echo "[Pulsar] Camera-local backup: $backup"
