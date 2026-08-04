#!/usr/bin/env bash
set -Eeuo pipefail

SERVER="${PULSAR_SERVER:-192.168.1.123}"
REMOTE_USER="${PULSAR_REMOTE_USER:-matin}"
REMOTE_ROOT="${PULSAR_REMOTE_ROOT:-/home/matin/Pulsar-Cpp-Core}"
LOCAL_ROOT="${PULSAR_LOCAL_ROOT:-$PWD}"
EXPECTED_PROFILE_SHA="a468f20e304e9543d4dc7aeb03b508a01e5257a8a3acdc59f81e11dba673c3f6"
TS="$(date +%Y%m%d-%H%M%S)"
BRANCH=""
SOCKET="/tmp/pulsar-reference-transport-v4-${USER}-$$"
LOCAL_LOG="$HOME/Downloads/pulsar-reference-transport-v4-$TS.log"
NEW_SOURCE="/tmp/CameraDevice-v4-$TS.cpp"
OLD_SOURCE="/tmp/CameraDevice-before-v4-$TS.cpp"
REMOTE_NEW="/tmp/CameraDevice-v4-$TS.cpp"
REMOTE_OLD="/tmp/CameraDevice-before-v4-$TS.cpp"
REMOTE_SCRIPT="/tmp/pulsar-reference-transport-v4-$TS.sh"
BEFORE_TAG="pulsar-before-reference-transport-$TS"
AFTER_TAG="pulsar-reference-transport-$TS"

mkdir -p "$HOME/Downloads"

cleanup() {
    ssh -S "$SOCKET" -O exit "$REMOTE_USER@$SERVER" >/dev/null 2>&1 || true
    rm -f "$SOCKET" "$NEW_SOURCE" "$OLD_SOURCE"
}
trap cleanup EXIT

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

if [[ "$(hostname -s 2>/dev/null || hostname)" == "pulsar" ]]; then
    fail "این اسکریپت را روی amin@localhost اجرا کن."
fi

[[ -f "$LOCAL_ROOT/CMakeLists.txt" ]] ||
    fail "اسکریپت را از ریشه پروژه اجرا کن."

[[ -f "$LOCAL_ROOT/camera/src/CameraDevice.cpp" ]] ||
    fail "CameraDevice.cpp پیدا نشد."

git -C "$LOCAL_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    fail "پروژه Git نیست."

cd "$LOCAL_ROOT"
BRANCH="$(git branch --show-current)"
[[ -n "$BRANCH" ]] || fail "Git روی detached HEAD است."

REMOTE_NAME="origin"
git remote get-url "$REMOTE_NAME" >/dev/null 2>&1 ||
    fail "Git remote origin پیدا نشد."

echo "============================================================"
echo "PULSAR REFERENCE TRANSPORT V4"
echo "Image profile will remain byte-identical."
echo "Local project: $LOCAL_ROOT"
echo "Remote project: $REMOTE_USER@$SERVER:$REMOTE_ROOT"
echo "Branch: $BRANCH"
echo "Permanent backup: GitHub tags only"
echo "============================================================"

echo
echo "[1/8] Verifying the exact image profile..."

for profile in \
    camera/profiles/FCU22080658-reference350.txt \
    camera/profiles/FCU22080659-reference350.txt
do
    [[ -f "$profile" ]] || fail "پروفایل پیدا نشد: $profile"
    actual="$(sha256sum "$profile" | awk '{print $1}')"
    [[ "$actual" == "$EXPECTED_PROFILE_SHA" ]] ||
        fail "هش پروفایل تغییر کرده است: $profile ($actual)"
done

echo "Image profile SHA256 verified: $EXPECTED_PROFILE_SHA"

echo
echo "[2/8] Saving the current state in GitHub..."

git add -A

if ! git diff --cached --quiet; then
    git commit -m "Checkpoint before reference transport V4 [$TS]"
fi

BEFORE_COMMIT="$(git rev-parse HEAD)"

if git rev-parse "$BEFORE_TAG" >/dev/null 2>&1; then
    fail "Git tag already exists: $BEFORE_TAG"
fi

git tag -a "$BEFORE_TAG" "$BEFORE_COMMIT" \
    -m "Before reference transport V4 $TS"

git push "$REMOTE_NAME" "$BRANCH"
git push "$REMOTE_NAME" "$BEFORE_TAG"

git show "$BEFORE_COMMIT:camera/src/CameraDevice.cpp" > "$OLD_SOURCE"

echo "Before commit: $BEFORE_COMMIT"
echo "Before tag: $BEFORE_TAG"

echo
echo "[3/8] Restoring only the reference USB transport parameters..."

python3 - "camera/src/CameraDevice.cpp" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

authority = "PULSAR_REFERENCE_PROFILE_AUTHORITY_V2"
marker = "PULSAR_REFERENCE_USB_TRANSPORT_V4"

if authority not in text:
    raise SystemExit(
        "ERROR: reference profile authority is not active; refusing to touch image path."
    )

if marker in text:
    print("Reference USB transport V4 was already present.")
    raise SystemExit(0)

old = '''  setInt(streamPort, "StreamTransferSize", 256 * 1024);
  setInt(streamPort, "StreamTransferNumberUrb", 64);'''

new = '''  // PULSAR_REFERENCE_USB_TRANSPORT_V4
  // Match the known-good ZIP transport for full 4024x3036 Bayer frames.
  // These are host/USB stream parameters and do not alter image pixels.
  setInt(streamPort, "StreamTransferSize", 1024 * 1024);
  setInt(streamPort, "StreamTransferNumberUrb", 200);
  setInt(streamPort, "AcquisitionBufferCachePrec", 40);'''

if old not in text:
    raise SystemExit(
        "ERROR: expected 256KB/64-URB transport block was not found."
    )

text = text.replace(old, new, 1)
path.write_text(text)
print("Patched: 256KB/64 URB -> 1MB/200 URB + cache 40")
PY

grep -q 'PULSAR_REFERENCE_USB_TRANSPORT_V4' \
    camera/src/CameraDevice.cpp

for profile in \
    camera/profiles/FCU22080658-reference350.txt \
    camera/profiles/FCU22080659-reference350.txt
do
    actual="$(sha256sum "$profile" | awk '{print $1}')"
    [[ "$actual" == "$EXPECTED_PROFILE_SHA" ]] ||
        fail "پروفایل تصویر هنگام Patch تغییر کرده است."
done

git add camera/src/CameraDevice.cpp

if git diff --cached --quiet; then
    echo "Source already contains the final transport tuning."
    AFTER_COMMIT="$(git rev-parse HEAD)"
else
    git commit -m \
        "Restore reference 1MB/200-URB transport for 12MP realtime [$TS]"
    AFTER_COMMIT="$(git rev-parse HEAD)"
fi

if git rev-parse "$AFTER_TAG" >/dev/null 2>&1; then
    fail "Git tag already exists: $AFTER_TAG"
fi

git tag -a "$AFTER_TAG" "$AFTER_COMMIT" \
    -m "Reference full-resolution realtime transport $TS"

git push "$REMOTE_NAME" "$BRANCH"
git push "$REMOTE_NAME" "$AFTER_TAG"

cp -a camera/src/CameraDevice.cpp "$NEW_SOURCE"

echo "After commit: $AFTER_COMMIT"
echo "After tag: $AFTER_TAG"

echo
echo "[4/8] Connecting to the server..."
echo "رمز SSH کاربر matin را یک‌بار وارد کن."

ssh \
    -M -S "$SOCKET" \
    -o ControlPersist=300 \
    -o StrictHostKeyChecking=accept-new \
    -fnN "$REMOTE_USER@$SERVER"

scp -o ControlPath="$SOCKET" \
    "$NEW_SOURCE" \
    "$REMOTE_USER@$SERVER:$REMOTE_NEW"

scp -o ControlPath="$SOCKET" \
    "$OLD_SOURCE" \
    "$REMOTE_USER@$SERVER:$REMOTE_OLD"

cat > /tmp/pulsar-reference-transport-v4-remote.sh <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${PULSAR_ROOT:?}"
TS="${PULSAR_TS:?}"
NEW_SOURCE="${PULSAR_NEW_SOURCE:?}"
OLD_SOURCE="${PULSAR_OLD_SOURCE:?}"
EXPECTED_PROFILE_SHA="${PULSAR_PROFILE_SHA:?}"
BEFORE_TAG="${PULSAR_BEFORE_TAG:?}"
AFTER_TAG="${PULSAR_AFTER_TAG:?}"

CAMERA_CPP="$ROOT/camera/src/CameraDevice.cpp"
BUILD_DIR="$ROOT/core/build-reference-transport-$TS"
CURRENT_BINARY="$ROOT/core/build/pulsar-core"
TEMP_OLD_BINARY="/tmp/pulsar-core-before-transport-$TS"
APP_LOG="$ROOT/core/data/pulsar.log"
BASELINE_LOG="/tmp/pulsar-transport-baseline-$TS.log"
AFTER_LOG="/tmp/pulsar-transport-after-$TS.log"
SOURCE_INSTALLED=0
BINARY_INSTALLED=0

cleanup() {
    rm -rf "$BUILD_DIR"
    rm -f \
        "$TEMP_OLD_BINARY" \
        "$BASELINE_LOG" \
        "$AFTER_LOG" \
        "$NEW_SOURCE" \
        "$OLD_SOURCE"
}

rollback() {
    code=$?
    trap - ERR

    echo
    echo "ERROR: transport update failed; restoring the running version..."

    if [[ "$SOURCE_INSTALLED" == "1" && -f "$OLD_SOURCE" ]]; then
        install -m 0644 "$OLD_SOURCE" "$CAMERA_CPP"
    fi

    if [[ "$BINARY_INSTALLED" == "1" && -x "$TEMP_OLD_BINARY" ]]; then
        install -m 0755 "$TEMP_OLD_BINARY" "$CURRENT_BINARY"
        sudo -n systemctl restart pulsar-kiosk.service >/dev/null 2>&1 || true
    fi

    echo "Permanent rollback point is in GitHub tag: $BEFORE_TAG"
    cleanup
    exit "$code"
}
trap rollback ERR
trap cleanup EXIT

summarize_log() {
    local file="$1"
    local title="$2"

    python3 - "$file" "$title" <<'PY'
from pathlib import Path
import math
import re
import statistics
import sys

path = Path(sys.argv[1])
title = sys.argv[2]
text = path.read_text(errors="ignore") if path.exists() else ""

patterns = {
    "camera_output_fps": r"(?:Left|Right) Camera: latency-stats.*?output-fps=(-?\d+(?:\.\d+)?)",
    "camera_dequeue_wait_ms": r"(?:Left|Right) Camera: latency-stats.*?dequeue-wait-ms=(-?\d+(?:\.\d+)?)",
    "camera_host_pipeline_ms": r"(?:Left|Right) Camera: latency-stats.*?host-pipeline-ms=(-?\d+(?:\.\d+)?)",
    "camera_gpu_total_ms": r"(?:Left|Right) Camera: latency-stats.*?gpu-total-ms=(-?\d+(?:\.\d+)?)",
    "renderer_loop_fps": r"SBS Renderer: latency-stats.*?loop-fps=(-?\d+(?:\.\d+)?)",
    "renderer_left_age_ms": r"SBS Renderer: latency-stats.*?left-host-age-ms=(-?\d+(?:\.\d+)?)",
    "renderer_right_age_ms": r"SBS Renderer: latency-stats.*?right-host-age-ms=(-?\d+(?:\.\d+)?)",
    "renderer_stereo_skew_ms": r"SBS Renderer: latency-stats.*?stereo-host-skew-ms=(-?\d+(?:\.\d+)?)",
    "renderer_upload_ms": r"SBS Renderer: latency-stats.*?texture-upload-ms=(-?\d+(?:\.\d+)?)",
    "renderer_present_ms": r"SBS Renderer: latency-stats.*?present-ms=(-?\d+(?:\.\d+)?)",
}

def percentile(values, p):
    values = sorted(values)
    if not values:
        return None
    k = (len(values) - 1) * p
    lo = math.floor(k)
    hi = math.ceil(k)
    if lo == hi:
        return values[lo]
    return values[lo] * (hi - k) + values[hi] * (k - lo)

print(f"--- {title} ---")
for name, pattern in patterns.items():
    values = [float(x) for x in re.findall(pattern, text)]
    if not values:
        print(f"{name}=no-samples")
        continue
    print(
        f"{name}: n={len(values)} "
        f"median={statistics.median(values):.3f} "
        f"p95={percentile(values, 0.95):.3f} "
        f"max={max(values):.3f}"
    )
PY
}

for required in \
    "$ROOT/CMakeLists.txt" \
    "$CAMERA_CPP" \
    "$ROOT/camera/profiles/FCU22080658-reference350.txt" \
    "$ROOT/camera/profiles/FCU22080659-reference350.txt"
do
    [[ -e "$required" ]] || {
        echo "ERROR: missing server file: $required"
        exit 1
    }
done

echo
echo "[5/8] Capturing the current latency baseline for 20 seconds..."

BASELINE_START="$(wc -l < "$APP_LOG" 2>/dev/null || echo 0)"
sleep 20
tail -n "+$((BASELINE_START + 1))" "$APP_LOG" \
    > "$BASELINE_LOG" 2>/dev/null || true

summarize_log "$BASELINE_LOG" "BEFORE REFERENCE TRANSPORT"

echo
echo "[6/8] Verifying that image settings remain untouched..."

for profile in \
    "$ROOT/camera/profiles/FCU22080658-reference350.txt" \
    "$ROOT/camera/profiles/FCU22080659-reference350.txt"
do
    actual="$(sha256sum "$profile" | awk '{print $1}')"
    [[ "$actual" == "$EXPECTED_PROFILE_SHA" ]] || {
        echo "ERROR: image profile checksum changed: $profile"
        exit 1
    }
done

grep -q 'PULSAR_REFERENCE_PROFILE_AUTHORITY_V2' "$NEW_SOURCE"
grep -q 'PULSAR_REFERENCE_USB_TRANSPORT_V4' "$NEW_SOURCE"

if [[ -x "$CURRENT_BINARY" ]]; then
    cp -a "$CURRENT_BINARY" "$TEMP_OLD_BINARY"
fi

install -m 0644 "$NEW_SOURCE" "$CAMERA_CPP"
SOURCE_INSTALLED=1

echo
echo "[7/8] Building CUDA/NPP separately while the current image stays running..."

rm -rf "$BUILD_DIR"

cmake \
    -S "$ROOT" \
    -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.2/bin/nvcc \
    -DCMAKE_CUDA_ARCHITECTURES=86

cmake --build "$BUILD_DIR" -j"$(nproc)"

test -x "$BUILD_DIR/pulsar-core"

ldd "$BUILD_DIR/pulsar-core" | grep -E \
    'libcudart|libnpp|libgxiapi|not found'

ldd "$BUILD_DIR/pulsar-core" | grep -q 'libcudart'
! ldd "$BUILD_DIR/pulsar-core" | grep -q 'not found'

mkdir -p "$ROOT/core/build"
install -m 0755 "$BUILD_DIR/pulsar-core" "$CURRENT_BINARY"
BINARY_INSTALLED=1

START_LINE="$(wc -l < "$APP_LOG" 2>/dev/null || echo 0)"
sudo -n systemctl restart pulsar-kiosk.service

for _ in $(seq 1 120); do
    NEW_LOG="$(tail -n "+$((START_LINE + 1))" "$APP_LOG" 2>/dev/null || true)"

    if systemctl is-active --quiet pulsar-kiosk.service &&
       pgrep -x pulsar-core >/dev/null 2>&1 &&
       [[ "$(grep -c 'configured sensor=4024x3036' <<<"$NEW_LOG")" -ge 2 ]] &&
       [[ "$(grep -c 'GPU pipeline ready' <<<"$NEW_LOG")" -ge 2 ]] &&
       [[ "$(grep -c \
           'stream-buffer-mode=NewestOnly acquisition-buffers=2' \
           <<<"$NEW_LOG")" -ge 2 ]]; then
        break
    fi

    sleep 1
done

echo
echo "[8/8] Measuring the optimized full-resolution path for 30 seconds..."

sleep 30
tail -n "+$((START_LINE + 1))" "$APP_LOG" \
    > "$AFTER_LOG" 2>/dev/null || true

summarize_log "$AFTER_LOG" "AFTER REFERENCE TRANSPORT"

echo
echo "=== STARTUP VALIDATION ==="
grep -aE \
    'imported GalaxyView profile|configured sensor=|stream-buffer-mode=|GPU pipeline ready|CPU fallback' \
    "$AFTER_LOG" |
    tail -n 60 || true

echo
echo "=== ERRORS ==="
grep -aEi \
    'GXImportConfigFile failed|required GalaxyView profile|CPU fallback|cuda.*(error|failed)|camera.*timeout|disconnect|reset|not found' \
    "$AFTER_LOG" |
    tail -n 40 || true

systemctl is-active --quiet pulsar-kiosk.service
pgrep -x pulsar-core >/dev/null

for profile in \
    "$ROOT/camera/profiles/FCU22080658-reference350.txt" \
    "$ROOT/camera/profiles/FCU22080659-reference350.txt"
do
    actual="$(sha256sum "$profile" | awk '{print $1}')"
    [[ "$actual" == "$EXPECTED_PROFILE_SHA" ]]
done

[[ "$(grep -c 'configured sensor=4024x3036' "$AFTER_LOG")" -ge 2 ]]
[[ "$(grep -c 'GPU pipeline ready' "$AFTER_LOG")" -ge 2 ]]
[[ "$(grep -c \
    'stream-buffer-mode=NewestOnly acquisition-buffers=2' \
    "$AFTER_LOG")" -ge 2 ]]

if grep -aEq \
    'GXImportConfigFile failed|required GalaxyView profile|CPU fallback' \
    "$AFTER_LOG"; then
    echo "ERROR: image profile or CUDA startup failed."
    exit 1
fi

BINARY_INSTALLED=0
SOURCE_INSTALLED=0

echo
echo "============================================================"
echo "FINAL_STATUS=REFERENCE_12MP_REALTIME_TRANSPORT_ACTIVE"
echo "Image profile SHA256: $EXPECTED_PROFILE_SHA"
echo "Image settings changed: NO"
echo "Sensor: 4024x3036"
echo "USB stream transfer: 1048576"
echo "USB URBs: 200"
echo "Acquisition cache: 40"
echo "Queue: NewestOnly"
echo "Acquisition buffers: 2"
echo "Permanent before tag: $BEFORE_TAG"
echo "Permanent after tag: $AFTER_TAG"
echo "============================================================"
REMOTE

chmod 700 /tmp/pulsar-reference-transport-v4-remote.sh

scp -o ControlPath="$SOCKET" \
    /tmp/pulsar-reference-transport-v4-remote.sh \
    "$REMOTE_USER@$SERVER:$REMOTE_SCRIPT"

set +e
ssh -o ControlPath="$SOCKET" \
    "$REMOTE_USER@$SERVER" \
    "PULSAR_ROOT='$REMOTE_ROOT' \
     PULSAR_TS='$TS' \
     PULSAR_NEW_SOURCE='$REMOTE_NEW' \
     PULSAR_OLD_SOURCE='$REMOTE_OLD' \
     PULSAR_PROFILE_SHA='$EXPECTED_PROFILE_SHA' \
     PULSAR_BEFORE_TAG='$BEFORE_TAG' \
     PULSAR_AFTER_TAG='$AFTER_TAG' \
     bash '$REMOTE_SCRIPT'" \
    2>&1 | tee "$LOCAL_LOG"

STATUS=${PIPESTATUS[0]}
set -e

echo
echo "============================================================"
echo "گزارش کامل:"
echo "$LOCAL_LOG"
echo "GitHub rollback tag:"
echo "$BEFORE_TAG"
echo "============================================================"

if [[ "$STATUS" -ne 0 ]]; then
    echo "اصلاح ناموفق بود و نسخه‌ی در حال اجرا بازیابی شد."
    exit "$STATUS"
fi