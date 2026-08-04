#!/usr/bin/env bash
set -Eeuo pipefail

SERVER="${PULSAR_SERVER:-192.168.1.123}"
REMOTE_USER="${PULSAR_REMOTE_USER:-matin}"
REMOTE_ROOT="${PULSAR_REMOTE_ROOT:-/home/matin/Pulsar-Cpp-Core}"
LOCAL_ROOT="${PULSAR_LOCAL_ROOT:-$PWD}"
TS="$(date +%Y%m%d-%H%M%S)"
SOCKET="/tmp/pulsar-rtx-direct-v5-no-git-${USER}-$$"
LOCAL_LOG="$HOME/Downloads/pulsar-rtx-direct-v5-no-git-$TS.log"
STAGE="/tmp/pulsar-rtx-direct-v5-no-git-$TS"
ARCHIVE="/tmp/pulsar-rtx-direct-v5-no-git-$TS.tar.gz"
REMOTE_ARCHIVE="/tmp/pulsar-rtx-direct-v5-no-git-$TS.tar.gz"
REMOTE_SCRIPT="/tmp/pulsar-rtx-direct-v5-no-git-$TS.sh"

REFERENCE_PROFILE_SHA="a468f20e304e9543d4dc7aeb03b508a01e5257a8a3acdc59f81e11dba673c3f6"
LOW_LATENCY_PROFILE_SHA="99db3367af2a09dfee95656cf157aec16444ed617efc54530594760655360018"
RENDERER_SHA="d22e6ebcb207890ca0ea4e21c3196d047410b2f2907999520930d9666c04de50"
DISPLAY_SCRIPT_SHA="0dcf34e3a0d28a527532fd7c1bfad0e8ebdfc8c5da56400aa30225d9b2b32653"

mkdir -p "$HOME/Downloads"

cleanup() {
    ssh -S "$SOCKET" -O exit "$REMOTE_USER@$SERVER" >/dev/null 2>&1 || true
    rm -rf "$STAGE"
    rm -f "$SOCKET" "$ARCHIVE"
}
trap cleanup EXIT

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ "$(hostname -s 2>/dev/null || hostname)" != "pulsar" ]] ||
    fail "این اسکریپت را روی amin@localhost اجرا کن."

[[ -f "$LOCAL_ROOT/CMakeLists.txt" ]] ||
    fail "اسکریپت را از ریشه پروژه اجرا کن."

[[ -f "$LOCAL_ROOT/camera/src/CameraDevice.cpp" ]] ||
    fail "CameraDevice.cpp پیدا نشد."

[[ -f "$LOCAL_ROOT/core/scripts/common.sh" ]] ||
    fail "common.sh پیدا نشد."

cd "$LOCAL_ROOT"

echo "============================================================"
echo "PULSAR RTX DIRECT LOW-LATENCY V5 NO-GIT"
echo "Quality and anti-flicker settings are locked."
echo "Local project: $LOCAL_ROOT"
echo "Server: $REMOTE_USER@$SERVER"
echo "Git/backup: disabled by request"
echo "============================================================"

echo
echo "[1/7] Installing the locked visual profile and single renderer locally..."

rm -rf "$STAGE"
mkdir -p \
    "$STAGE/camera/src" \
    "$STAGE/camera/profiles" \
    "$STAGE/core/scripts" \
    "$STAGE/core/config"

base64 -d <<'RENDERER_GZ' | gzip -d > "$STAGE/camera/src/SbsRenderer.cpp"
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
RENDERER_GZ

base64 -d <<'PROFILE_GZ' | gzip -d > "$STAGE/camera/profiles/FCU22080658-reference350-realtime.txt"
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
PROFILE_GZ

cp -a \
    "$STAGE/camera/profiles/FCU22080658-reference350-realtime.txt" \
    "$STAGE/camera/profiles/FCU22080659-reference350-realtime.txt"

base64 -d <<'DISPLAY_GZ' | gzip -d > "$STAGE/core/scripts/configure-displays.sh"
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
DISPLAY_GZ

chmod +x "$STAGE/core/scripts/configure-displays.sh"

[[ "$(sha256sum "$STAGE/camera/src/SbsRenderer.cpp" | awk '{print $1}')" == "$RENDERER_SHA" ]]
[[ "$(sha256sum "$STAGE/core/scripts/configure-displays.sh" | awk '{print $1}')" == "$DISPLAY_SCRIPT_SHA" ]]

for profile in \
    "$STAGE/camera/profiles/FCU22080658-reference350-realtime.txt" \
    "$STAGE/camera/profiles/FCU22080659-reference350-realtime.txt"
do
    [[ "$(sha256sum "$profile" | awk '{print $1}')" == "$LOW_LATENCY_PROFILE_SHA" ]]
done

# The only difference from the byte-exact visual reference is the non-visual
# stream queue policy: OldestFirst -> NewestOnly.
python3 - "$STAGE/camera/profiles/FCU22080658-reference350-realtime.txt" <<'PY'
from pathlib import Path
import hashlib
import sys

path = Path(sys.argv[1])
actual = path.read_text(errors="strict")
reference = actual.replace(
    "StreamBufferHandlingMode\tNewestOnly",
    "StreamBufferHandlingMode\tOldestFirst",
    1,
)

if actual.count("StreamBufferHandlingMode\tNewestOnly") != 1:
    raise SystemExit("ERROR: NewestOnly stream policy is missing.")

expected = "a468f20e304e9543d4dc7aeb03b508a01e5257a8a3acdc59f81e11dba673c3f6"
digest = hashlib.sha256(reference.encode()).hexdigest()

if digest != expected:
    raise SystemExit(
        f"ERROR: visual reference changed: expected={expected} actual={digest}"
    )

print("Visual reference is byte-identical; only queue policy changed.")
PY

cp -a "$STAGE/camera/src/SbsRenderer.cpp" \
    "$LOCAL_ROOT/camera/src/SbsRenderer.cpp"

cp -a "$STAGE/camera/profiles/"*.txt \
    "$LOCAL_ROOT/camera/profiles/"

cp -a "$STAGE/core/scripts/configure-displays.sh" \
    "$LOCAL_ROOT/core/scripts/configure-displays.sh"

chmod +x "$LOCAL_ROOT/core/scripts/configure-displays.sh"
bash -n "$LOCAL_ROOT/core/scripts/configure-displays.sh"

grep -q 'PULSAR_REFERENCE_PROFILE_AUTHORITY_V2' \
    "$LOCAL_ROOT/camera/src/CameraDevice.cpp" ||
    fail "محافظ کیفیت مرجع در CameraDevice.cpp فعال نیست."

echo
echo "[2/7] Applying low-latency configuration without changing image controls..."

python3 - \
    "$LOCAL_ROOT/core/config/pulsar.env" \
    "$LOCAL_ROOT/core/config/pulsar.local.env" <<'PY'
from pathlib import Path
import sys

settings = {
    "PULSAR_LEFT_CAMERA_SERIAL": "FCU22080658",
    "PULSAR_RIGHT_CAMERA_SERIAL": "FCU22080659",
    "PULSAR_LEFT_CAMERA_PROFILE":
        "camera/profiles/FCU22080658-reference350-realtime.txt",
    "PULSAR_RIGHT_CAMERA_PROFILE":
        "camera/profiles/FCU22080659-reference350-realtime.txt",
    "PULSAR_CAMERA_PROFILE_ENABLED": "1",
    "PULSAR_CAMERA_PROFILE_VERIFY": "1",
    "PULSAR_CAMERA_PROFILE_REQUIRED": "1",

    # Preserve exact reference image ownership.
    "PULSAR_CAMERA_FPS": "32",
    "PULSAR_GPU_PIPELINE": "both",
    "PULSAR_GL_PBO_UPLOAD": "1",
    "PULSAR_STEREO_PAIRING_MODE": "latest",

    # One SDL/OpenGL target; XRandR clones it to every RTX viewing output.
    "PULSAR_SBS_PRESENT_VSYNC": "0",
    "PULSAR_MIRROR_ALL_REMAINING": "1",
    "PULSAR_DISPLAY_HOTPLUG_WATCH": "0",
    "PULSAR_AUDIO_HOTPLUG_WATCH": "0",
    "PULSAR_RENDER_MAIN": "1",
    "PULSAR_CORE_NVIDIA_OFFLOAD": "0",
    "PULSAR_BROWSER_GPU": "1",

    # Disable driver-level vblank wait for the realtime SBS process.
    "__GL_SYNC_TO_VBLANK": "0",
    "vblank_mode": "0",
}

for filename in sys.argv[1:]:
    path = Path(filename)
    if not path.exists():
        path.touch()

    lines = path.read_text(errors="replace").splitlines()
    output = []
    seen = set()

    for line in lines:
        stripped = line.strip()

        if not stripped or stripped.startswith("#") or "=" not in line:
            output.append(line)
            continue

        key = line.split("=", 1)[0].strip()

        if key in settings:
            if key not in seen:
                output.append(f"{key}={settings[key]}")
                seen.add(key)
            continue

        output.append(line)

    missing = [key for key in settings if key not in seen]
    if missing:
        output.extend(["", "# RTX direct single-render low-latency V5"])
        output.extend(f"{key}={settings[key]}" for key in missing)

    path.write_text("\n".join(output).rstrip() + "\n")
PY

cp -a "$LOCAL_ROOT/core/config/pulsar.env" \
    "$STAGE/core/config/pulsar.env"

cp -a "$LOCAL_ROOT/core/config/pulsar.local.env" \
    "$STAGE/core/config/pulsar.local.env"

echo
echo
echo "[3/7] Creating deployment payload without Git or backup..."

tar -C "$STAGE" -czf "$ARCHIVE" .

cat > /tmp/pulsar-rtx-direct-v5-no-git-remote.sh <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${PULSAR_ROOT:?}"
TS="${PULSAR_TS:?}"
ARCHIVE="${PULSAR_ARCHIVE:?}"
REFERENCE_PROFILE_SHA="${PULSAR_REFERENCE_PROFILE_SHA:?}"
LOW_LATENCY_PROFILE_SHA="${PULSAR_LOW_LATENCY_PROFILE_SHA:?}"
RENDERER_SHA="${PULSAR_RENDERER_SHA:?}"
DISPLAY_SCRIPT_SHA="${PULSAR_DISPLAY_SHA:?}"
STAGE="/tmp/pulsar-rtx-direct-stage-$TS"
BUILD_DIR="$ROOT/core/build-rtx-direct-$TS"
APP_LOG="$ROOT/core/data/pulsar.log"
CURRENT_BINARY="$ROOT/core/build/pulsar-core"
WORK_ROOT="/tmp/pulsar-rtx-direct-work-$TS"

cleanup() {
    rm -rf "$STAGE" "$BUILD_DIR" "$WORK_ROOT"
    rm -f "$ARCHIVE"
}
trap cleanup EXIT

mkdir -p "$STAGE" "$ROOT/core/data"
tar -C "$STAGE" -xzf "$ARCHIVE"

echo
echo "[4/7] Validating payload and current camera hardware..."

[[ "$(sha256sum "$STAGE/camera/src/SbsRenderer.cpp" | awk '{print $1}')" == "$RENDERER_SHA" ]]
[[ "$(sha256sum "$STAGE/core/scripts/configure-displays.sh" | awk '{print $1}')" == "$DISPLAY_SCRIPT_SHA" ]]

for profile in \
    "$STAGE/camera/profiles/FCU22080658-reference350-realtime.txt" \
    "$STAGE/camera/profiles/FCU22080659-reference350-realtime.txt"
do
    [[ "$(sha256sum "$profile" | awk '{print $1}')" == "$LOW_LATENCY_PROFILE_SHA" ]]
done

python3 - \
    "$STAGE/camera/profiles/FCU22080658-reference350-realtime.txt" \
    "$REFERENCE_PROFILE_SHA" <<'PY'
from pathlib import Path
import hashlib
import sys

text = Path(sys.argv[1]).read_text(errors="strict")
reference = text.replace(
    "StreamBufferHandlingMode\tNewestOnly",
    "StreamBufferHandlingMode\tOldestFirst",
    1,
)
digest = hashlib.sha256(reference.encode()).hexdigest()

if digest != sys.argv[2]:
    raise SystemExit("ERROR: visual camera profile differs from the reference.")

print("Visual camera profile verified; pixels/settings are unchanged.")
PY

echo
echo "=== USB CAMERA TOPOLOGY ==="
lsusb -t || true
camera_nodes=()
for node in /sys/bus/usb/devices/*; do
    [[ -r "$node/idVendor" ]] || continue
    [[ "$(cat "$node/idVendor")" == "2ba2" ]] || continue
    camera_nodes+=("$(basename "$node")")
done

printf 'Daheng camera USB nodes: %s\n' "${camera_nodes[*]:-none}"

root_buses=()
for node in "${camera_nodes[@]}"; do
    root_buses+=("${node%%-*}")
done

unique_buses="$(printf '%s\n' "${root_buses[@]}" | sort -u | sed '/^$/d' | wc -l)"

if ((${#camera_nodes[@]} >= 2 && unique_buses < 2)); then
    echo "HARDWARE_LIMIT=CAMERAS_SHARE_ONE_USB_ROOT_CONTROLLER"
    echo "Required raw payload at 32 FPS: about 781 MB/s for two 4024x3036 Bayer8 cameras."
    echo "One 5Gbps USB controller is 625 MB/s theoretical before protocol overhead."
    echo "To reach the camera's full rate without lowering quality, move one camera to a different xHCI controller or a PCIe USB3 card."
else
    echo "HARDWARE_LIMIT=NO_SHARED_USB_ROOT_DETECTED"
fi

echo
echo "[5/7] Building CUDA/NPP in an isolated temporary tree..."

rm -rf "$WORK_ROOT" "$BUILD_DIR"
mkdir -p "$WORK_ROOT"

# Copy the source into a disposable build tree. No backup is created.
rsync -a \
    --exclude='.git/' \
    --exclude='.pulsar-backups/' \
    --exclude='core/build*/' \
    --exclude='core/data/' \
    "$ROOT/" "$WORK_ROOT/"

cp -a "$STAGE/camera/src/SbsRenderer.cpp" \
    "$WORK_ROOT/camera/src/SbsRenderer.cpp"

cp -a "$STAGE/camera/profiles/"*.txt \
    "$WORK_ROOT/camera/profiles/"

cp -a "$STAGE/core/scripts/configure-displays.sh" \
    "$WORK_ROOT/core/scripts/configure-displays.sh"

cp -a "$STAGE/core/config/pulsar.env" \
    "$WORK_ROOT/core/config/pulsar.env"

cp -a "$STAGE/core/config/pulsar.local.env" \
    "$WORK_ROOT/core/config/pulsar.local.env"

chmod +x "$WORK_ROOT/core/scripts/configure-displays.sh"
bash -n "$WORK_ROOT/core/scripts/configure-displays.sh"

BUILD_DIR="$WORK_ROOT/core/build-rtx-direct"

cmake \
    -S "$WORK_ROOT" \
    -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.2/bin/nvcc \
    -DCMAKE_CUDA_ARCHITECTURES=86

cmake --build "$BUILD_DIR" -j"$(nproc)"

test -x "$BUILD_DIR/pulsar-core"
ldd "$BUILD_DIR/pulsar-core" | grep -q 'libcudart'
! ldd "$BUILD_DIR/pulsar-core" | grep -q 'not found'
echo
echo "[6/7] Installing only after successful build, then restarting once..."

# The build is complete. Apply source/configuration and binary now.
cp -a "$STAGE/camera/src/SbsRenderer.cpp"     "$ROOT/camera/src/SbsRenderer.cpp"
cp -a "$STAGE/camera/profiles/"*.txt     "$ROOT/camera/profiles/"
cp -a "$STAGE/core/scripts/configure-displays.sh"     "$ROOT/core/scripts/configure-displays.sh"
cp -a "$STAGE/core/config/pulsar.env"     "$ROOT/core/config/pulsar.env"
cp -a "$STAGE/core/config/pulsar.local.env"     "$ROOT/core/config/pulsar.local.env"
chmod +x "$ROOT/core/scripts/configure-displays.sh"

mkdir -p "$ROOT/core/build"
install -m 0755 "$BUILD_DIR/pulsar-core" "$CURRENT_BINARY"

PRE_RESTART_LINE="$(wc -l < "$APP_LOG" 2>/dev/null || echo 0)"
sudo -n systemctl restart pulsar-kiosk.service

for _ in $(seq 1 150); do
    startup="$(tail -n "+$((PRE_RESTART_LINE + 1))" "$APP_LOG" 2>/dev/null || true)"

    if systemctl is-active --quiet pulsar-kiosk.service &&
       pgrep -x pulsar-core >/dev/null 2>&1 &&
       [[ "$(grep -c 'GPU pipeline ready' <<<"$startup")" -ge 2 ]] &&
       grep -q 'direct-rtx-single-target=1' <<<"$startup"; then
        break
    fi

    sleep 1
done

systemctl is-active --quiet pulsar-kiosk.service
pgrep -x pulsar-core >/dev/null

# Start steady-state validation after the new CUDA pipelines are ready.
READY_LINE="$(wc -l < "$APP_LOG" 2>/dev/null || echo 0)"
sleep 30
STEADY_LOG="/tmp/pulsar-rtx-v5-steady-$TS.log"
tail -n "+$((READY_LINE + 1))" "$APP_LOG" > "$STEADY_LOG" 2>/dev/null || true

echo
echo "[7/7] Verifying RTX outputs and the single render target..."

DISPLAY=:0 XAUTHORITY=/home/matin/.Xauthority \
    xrandr --query || true

echo
echo "=== DISPLAY ROUTING ENV ==="
cat "$ROOT/core/data/displays.env"

grep -q '^PULSAR_AUX_OUTPUTS=$' "$ROOT/core/data/displays.env"
grep -q '^PULSAR_AUX_COUNT=0$' "$ROOT/core/data/displays.env"
grep -q '^PULSAR_RENDER_MAIN=1$' "$ROOT/core/data/displays.env"

main_output="$(awk -F= '$1=="PULSAR_MAIN_OUTPUT"{print $2}' "$ROOT/core/data/displays.env")"
main_geometry="$(
    DISPLAY=:0 XAUTHORITY=/home/matin/.Xauthority xrandr --query |
    awk -v out="$main_output" '$1==out && $2=="connected" {
      for(i=3;i<=NF;i++) if($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+/) {print $i; exit}
    }'
)"

[[ -n "$main_output" && -n "$main_geometry" ]]

echo "Main RTX output: $main_output $main_geometry"
echo "All active RTX viewing outputs sharing the main scanout:"

DISPLAY=:0 XAUTHORITY=/home/matin/.Xauthority xrandr --query |
awk -v geometry="$main_geometry" '
  $2=="connected" {
    active=""
    for(i=3;i<=NF;i++) {
      if($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+/) active=$i
    }
    if(active==geometry && ($1 ~ /^DP-/ || $1 ~ /^HDMI-1-/ || $1 ~ /^DVI-/)) {
      print "  " $1 " " active
      count++
    }
  }
  END {
    print "RTX_CLONE_COUNT=" count
    if(count < 1) exit 1
  }
'

echo
echo "=== NEW STEADY-STATE LOG ==="
grep -aE \
    'direct-rtx-single-target=|stereo-pairing-mode=|configured sensor=|GPU pipeline ready|latency-stats' \
    "$STEADY_LOG" |
    tail -n 80 || true

if grep -aEq \
    'CPU fallback active|GXImportConfigFile failed|required GalaxyView profile|cuda.*failed' \
    "$STEADY_LOG"; then
    echo "ERROR: steady-state CUDA/profile validation failed."
    exit 1
fi

echo
echo "[POST] Calculating actual post-ready latency..."

python3 - "$STEADY_LOG" <<'PY'
from pathlib import Path
import math
import re
import statistics
import sys

text = Path(sys.argv[1]).read_text(errors="ignore")

patterns = {
    "camera_output_fps":
        r"(?:Left|Right) Camera: latency-stats.*?output-fps=(-?\d+(?:\.\d+)?)",
    "camera_host_pipeline_ms":
        r"(?:Left|Right) Camera: latency-stats.*?host-pipeline-ms=(-?\d+(?:\.\d+)?)",
    "camera_gpu_total_ms":
        r"(?:Left|Right) Camera: latency-stats.*?gpu-total-ms=(-?\d+(?:\.\d+)?)",
    "renderer_loop_fps":
        r"SBS Renderer: latency-stats.*?loop-fps=(-?\d+(?:\.\d+)?)",
    "renderer_left_age_ms":
        r"SBS Renderer: latency-stats.*?left-host-age-ms=(-?\d+(?:\.\d+)?)",
    "renderer_right_age_ms":
        r"SBS Renderer: latency-stats.*?right-host-age-ms=(-?\d+(?:\.\d+)?)",
    "renderer_upload_ms":
        r"SBS Renderer: latency-stats.*?texture-upload-ms=(-?\d+(?:\.\d+)?)",
    "renderer_present_ms":
        r"SBS Renderer: latency-stats.*?present-ms=(-?\d+(?:\.\d+)?)",
}

def percentile(values, fraction):
    values = sorted(values)
    if not values:
        return None
    point = (len(values) - 1) * fraction
    low = math.floor(point)
    high = math.ceil(point)
    if low == high:
        return values[low]
    return values[low] * (high - point) + values[high] * (point - low)

results = {}
for name, pattern in patterns.items():
    values = [float(value) for value in re.findall(pattern, text)]
    results[name] = values

for name, values in results.items():
    if not values:
        print(f"{name}=no-samples")
        continue

    print(
        f"{name}: n={len(values)} "
        f"median={statistics.median(values):.3f} "
        f"p95={percentile(values, 0.95):.3f} "
        f"max={max(values):.3f}"
    )

gpu = results["camera_gpu_total_ms"]
present = results["renderer_present_ms"]
upload = results["renderer_upload_ms"]

if gpu and percentile(gpu, 0.95) >= 10:
    raise SystemExit("ERROR: CUDA processing p95 is not below 10ms.")

if present and percentile(present, 0.95) >= 10:
    raise SystemExit("ERROR: display present p95 is not below 10ms.")

if upload and percentile(upload, 0.95) >= 10:
    raise SystemExit("ERROR: texture upload p95 is not below 10ms.")

print("PROCESSING_TARGET=GPU_UPLOAD_PRESENT_P95_BELOW_10MS")
print(
    "END_TO_END_NOTE=30ms exposure and the camera frame interval prevent "
    "sub-10ms sensor-to-display latency."
)
PY

echo
echo "============================================================"
echo "FINAL_STATUS=RTX_DIRECT_SINGLE_RENDER_ACTIVE"
echo "Image/anti-flicker changed: NO"
echo "Reference visual SHA256: $REFERENCE_PROFILE_SHA"
echo "Realtime profile SHA256: $LOW_LATENCY_PROFILE_SHA"
echo "Renderer targets: 1"
echo "RTX outputs: hardware-cloned by XRandR"
echo "VSync wait: disabled"
echo "Pairing: latest-zero-hold"
echo "Git/backup: disabled"
echo "============================================================"
REMOTE

chmod 700 /tmp/pulsar-rtx-direct-v5-no-git-remote.sh

echo
echo "Connecting to $REMOTE_USER@$SERVER ..."
echo "رمز SSH کاربر matin را یک‌بار وارد کن."

ssh \
    -M -S "$SOCKET" \
    -o ControlPersist=300 \
    -o StrictHostKeyChecking=accept-new \
    -fnN "$REMOTE_USER@$SERVER"

scp -o ControlPath="$SOCKET" \
    "$ARCHIVE" \
    "$REMOTE_USER@$SERVER:$REMOTE_ARCHIVE"

scp -o ControlPath="$SOCKET" \
    /tmp/pulsar-rtx-direct-v5-no-git-remote.sh \
    "$REMOTE_USER@$SERVER:$REMOTE_SCRIPT"

set +e
ssh -o ControlPath="$SOCKET" \
    "$REMOTE_USER@$SERVER" \
    "PULSAR_ROOT='$REMOTE_ROOT' \
     PULSAR_TS='$TS' \
     PULSAR_ARCHIVE='$REMOTE_ARCHIVE' \
     PULSAR_REFERENCE_PROFILE_SHA='$REFERENCE_PROFILE_SHA' \
     PULSAR_LOW_LATENCY_PROFILE_SHA='$LOW_LATENCY_PROFILE_SHA' \
     PULSAR_RENDERER_SHA='$RENDERER_SHA' \
     PULSAR_DISPLAY_SHA='$DISPLAY_SCRIPT_SHA' \
     bash '$REMOTE_SCRIPT'" \
    2>&1 | tee "$LOCAL_LOG"

STATUS=${PIPESTATUS[0]}
set -e

echo
echo "============================================================"
echo "گزارش اجرا:"
echo "$LOCAL_LOG"
echo "Git/backup: disabled"
echo "============================================================"

if [[ "$STATUS" -ne 0 ]]; then
    echo "اصلاح ناموفق بود؛ گزارش بالا را بررسی کن."
    exit "$STATUS"
fi
