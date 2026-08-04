#!/usr/bin/env bash
set -Eeuo pipefail

SERVER="${PULSAR_SERVER:-192.168.1.123}"
REMOTE_USER="${PULSAR_REMOTE_USER:-matin}"
REMOTE_ROOT="${PULSAR_REMOTE_ROOT:-/home/matin/Pulsar-Cpp-Core}"
LOCAL_ROOT="${PULSAR_LOCAL_ROOT:-$PWD}"
TS="$(date +%Y%m%d-%H%M%S)"
EXPECTED_PROFILE_SHA="a468f20e304e9543d4dc7aeb03b508a01e5257a8a3acdc59f81e11dba673c3f6"

SOCKET="/tmp/pulsar-reference-authority-${USER}-$$"
LOCAL_LOG="$HOME/Downloads/pulsar-reference-authority-$TS.log"
PAYLOAD="/tmp/pulsar-reference-authority-$TS.tar.gz"
REMOTE_PAYLOAD="/tmp/pulsar-reference-authority-$TS.tar.gz"
REMOTE_SCRIPT="/tmp/pulsar-reference-authority-$TS.sh"


if [[ ! -f "$LOCAL_ROOT/CMakeLists.txt" ||
      ! -f "$LOCAL_ROOT/camera/src/CameraDevice.cpp" ||
      ! -f "$LOCAL_ROOT/core/config/pulsar.local.env" ]]; then
    echo "ERROR: این اسکریپت را از ریشه پروژه اجرا کن:"
    echo "  cd ~/Music/Pulsar-Cpp-Core-PreStage8-Downloaded"
    exit 1
fi

if [[ "$(hostname -s 2>/dev/null || hostname)" == "pulsar" ]]; then
    echo "ERROR: این اسکریپت را روی amin@localhost اجرا کن."
    exit 1
fi

cleanup() {
    ssh -S "$SOCKET" -O exit "$REMOTE_USER@$SERVER" >/dev/null 2>&1 || true
    rm -f "$SOCKET" "$PAYLOAD"
}

trap cleanup EXIT

cd "$LOCAL_ROOT"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "ERROR: پروژه محلی Git repository نیست."
    exit 1
}

GIT_BRANCH="$(git branch --show-current)"
[[ -n "$GIT_BRANCH" ]] || {
    echo "ERROR: Git در حالت detached HEAD است."
    exit 1
}

git remote get-url origin >/dev/null 2>&1 || {
    echo "ERROR: Git remote با نام origin پیدا نشد."
    exit 1
}

echo "============================================================"
echo "PULSAR EXACT REFERENCE IMAGE + LOW LATENCY V3"
echo "Local project: $LOCAL_ROOT"
echo "Remote project: $REMOTE_USER@$SERVER:$REMOTE_ROOT"
echo "Profile SHA256: $EXPECTED_PROFILE_SHA"
echo "Backup policy: GitHub commits/tags only (no local backup directory)"
echo "============================================================"

echo
echo "[0/8] Saving the current project state to GitHub..."

git add -A
if ! git diff --cached --quiet; then
    git commit -m "Checkpoint before exact reference image fix [$TS]"
fi

BEFORE_COMMIT="$(git rev-parse HEAD)"
BEFORE_TAG="pulsar-before-reference-image-$TS-${BEFORE_COMMIT:0:12}"

git tag -f "$BEFORE_TAG" "$BEFORE_COMMIT"
git push origin "$GIT_BRANCH"
git push origin "refs/tags/$BEFORE_TAG"

echo "GitHub checkpoint commit: $BEFORE_COMMIT"
echo "GitHub checkpoint tag: $BEFORE_TAG"

echo
echo "[1/8] Installing the byte-exact reference profiles locally..."

mkdir -p "$LOCAL_ROOT/camera/profiles"

base64 -d <<'PROFILE_GZ_B64' | gzip -d \
    > "$LOCAL_ROOT/camera/profiles/FCU22080658-reference350.txt"
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
PROFILE_GZ_B64

cp -a \
    "$LOCAL_ROOT/camera/profiles/FCU22080658-reference350.txt" \
    "$LOCAL_ROOT/camera/profiles/FCU22080659-reference350.txt"

for profile in \
    "$LOCAL_ROOT/camera/profiles/FCU22080658-reference350.txt" \
    "$LOCAL_ROOT/camera/profiles/FCU22080659-reference350.txt"
do
    actual="$(sha256sum "$profile" | awk '{print $1}')"
    if [[ "$actual" != "$EXPECTED_PROFILE_SHA" ]]; then
        echo "ERROR: هش پروفایل اشتباه است: $profile"
        exit 1
    fi
done

echo
echo "[2/8] Making the imported profile authoritative..."

python3 - "$LOCAL_ROOT" <<'PY_PATCH'
from pathlib import Path
import sys

root = Path(sys.argv[1])
camera_path = root / "camera/src/CameraDevice.cpp"
env_paths = [
    root / "core/config/pulsar.env",
    root / "core/config/pulsar.local.env",
]

text = camera_path.read_text()

def replace_function(source: str, signature: str, replacement: str) -> str:
    start = source.find(signature)
    if start < 0:
        raise SystemExit(f"ERROR: function not found: {signature}")

    opening = source.find("{", start)
    if opening < 0:
        raise SystemExit(f"ERROR: opening brace not found: {signature}")

    depth = 0
    end = None
    in_string = False
    quote = ""
    escaped = False

    for index in range(opening, len(source)):
        char = source[index]

        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                in_string = False
            continue

        if char in ('"', "'"):
            in_string = True
            quote = char
            continue

        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                end = index + 1
                break

    if end is None:
        raise SystemExit(f"ERROR: function is not balanced: {signature}")

    return source[:start] + replacement + source[end:]

configure_function = r'''bool CameraDevice::configure() {
  profileImported_ = false;
  controlsApplied_ = false;

  if (profileEnabled_) {
    if (!importGalaxyProfile() && profileRequired_) {
      std::cerr << label_ << ": required GalaxyView profile could not be loaded\n";
      return false;
    }
  }

  // PULSAR_REFERENCE_PROFILE_AUTHORITY_V2
  // The imported GalaxyView file owns all sensor and image parameters.
  // Runtime controls are allowed only when no profile was imported.
  if (!profileImported_) {
    if (setEnumOneOf(device_, "UserSetSelector", {"Default", "UserSet0"})) {
      setCommand(device_, "UserSetLoad");
    }
    applyLowLatencyAcquisitionSetup(device_, targetFps_);

    setEnumOneOf(device_, "RegionSelector", {"Region0", "Region1"});
    setEnum(device_, "RegionMode", "Off");

    GX_INT_VALUE sensorWidthMax{};
    GX_INT_VALUE sensorHeightMax{};
    const bool haveSensorWidth = getInt(device_, "WidthMax", sensorWidthMax);
    const bool haveSensorHeight = getInt(device_, "HeightMax", sensorHeightMax);
    int sensorScale = std::clamp(sensorScale_, 1, 4);

    if (haveSensorWidth && haveSensorHeight) {
      const double widthRatio =
          static_cast<double>(sensorWidthMax.nCurValue) / std::max(1u, maxWidth_);
      const double heightRatio =
          static_cast<double>(sensorHeightMax.nCurValue) / std::max(1u, maxHeight_);
      const int recommendedScale = std::clamp(
          static_cast<int>(std::ceil(std::max({1.0, widthRatio, heightRatio}))),
          1,
          4);
      sensorScale = std::max(sensorScale, recommendedScale);
    }

    configuredSensorScale_ = sensorScale;
    setEnumOneOf(device_, "BinningHorizontalMode", {"Average", "Sum"});
    setEnumOneOf(device_, "BinningVerticalMode", {"Average", "Sum"});
    setInt(device_, "BinningHorizontal", sensorScale);
    setInt(device_, "BinningVertical", sensorScale);
    setInt(device_, "DecimationHorizontal", 1);
    setInt(device_, "DecimationVertical", 1);
    setInt(device_, "SensorDecimationHorizontal", 1);
    setInt(device_, "SensorDecimationVertical", 1);
    setBool(device_, "CenterX", false);
    setBool(device_, "CenterY", false);

    GX_INT_VALUE widthMax{};
    GX_INT_VALUE heightMax{};

    if (getInt(device_, "WidthMax", widthMax)) {
      setInt(device_, "Width", widthMax.nCurValue);
    }
    if (getInt(device_, "HeightMax", heightMax)) {
      setInt(device_, "Height", heightMax.nCurValue);
    }

    setInt(device_, "OffsetX", 0);
    setInt(device_, "OffsetY", 0);
    applyControls(controls_(), true);
  }

  // Keep only host-side latency optimizations outside profile authority.
  // These do not alter exposure, gain, color, LUT, ROI or sensor geometry.
  GX_DS_HANDLE streamHandle = nullptr;
  const bool haveStreamHandle =
      GXGetDataStreamHandleFromDev(device_, 0, &streamHandle) ==
          GX_STATUS_SUCCESS &&
      streamHandle != nullptr;

  GX_PORT_HANDLE streamPort = haveStreamHandle
      ? static_cast<GX_PORT_HANDLE>(streamHandle)
      : static_cast<GX_PORT_HANDLE>(device_);

  setInt(streamPort, "StreamTransferSize", 256 * 1024);
  setInt(streamPort, "StreamTransferNumberUrb", 64);
  setBool(device_, "FrameStoreCoverActive", true);
  setEnum(device_, "CoverFrameStoreMode", "On");

  const char* streamBufferMode = "unchanged";

  if (setEnum(streamPort, "StreamBufferHandlingMode", "NewestOnly")) {
    streamBufferMode = "NewestOnly";
  } else if (
      setEnum(streamPort, "StreamBufferHandlingMode", "OldestFirstOverwrite")) {
    streamBufferMode = "OldestFirstOverwrite";
  }

  constexpr uint64_t kAcquisitionBufferCount = 2;

  if (GXSetAcqusitionBufferNumber(device_, kAcquisitionBufferCount) !=
      GX_STATUS_SUCCESS) {
    std::cerr << label_
              << ": warning: could not set acquisition buffer count\n";
  }

  std::cerr << label_ << ": low-latency stream-buffer-mode="
            << streamBufferMode << " acquisition-buffers="
            << kAcquisitionBufferCount << '\n';

  colorFilter_ = GX_COLOR_FILTER_NONE;

  if (available(device_, "PixelColorFilter")) {
    GX_ENUM_VALUE value{};

    if (GXGetEnumValue(device_, "PixelColorFilter", &value) ==
        GX_STATUS_SUCCESS) {
      colorFilter_ = value.stCurValue.nCurValue;
    }
  }

  return true;
}'''

text = replace_function(
    text,
    "bool CameraDevice::configure()",
    configure_function,
)

apply_signature = (
    "void CameraDevice::applyControls("
    "const core::CameraControls& controls, bool force) {"
)
apply_start = text.find(apply_signature)

if apply_start < 0:
    raise SystemExit("ERROR: applyControls function not found.")

insert_at = apply_start + len(apply_signature)
guard_marker = "PULSAR_REFERENCE_APPLY_GUARD_V2"

if guard_marker not in text[insert_at:insert_at + 600]:
    guard = r'''
  // PULSAR_REFERENCE_APPLY_GUARD_V2
  // The imported profile is the single source of truth for exposure, gain,
  // black level, white balance, gamma, LUT and sensor geometry.
  if (profileImported_) return;
'''
    text = text[:insert_at] + guard + text[insert_at:]

redundant_guard = r'''
  if (profileImported_) {
    appliedControls_ = controls;
    controlsApplied_ = true;
    return;
  }
'''
text = text.replace(redundant_guard, "\n", 1)

camera_path.write_text(text)

settings = {
    "PULSAR_LEFT_CAMERA_SERIAL": "FCU22080658",
    "PULSAR_RIGHT_CAMERA_SERIAL": "FCU22080659",
    "PULSAR_LEFT_CAMERA_PROFILE":
        "camera/profiles/FCU22080658-reference350.txt",
    "PULSAR_RIGHT_CAMERA_PROFILE":
        "camera/profiles/FCU22080659-reference350.txt",
    "PULSAR_CAMERA_PROFILE_ENABLED": "1",
    "PULSAR_CAMERA_PROFILE_VERIFY": "1",
    "PULSAR_CAMERA_PROFILE_REQUIRED": "1",
    "PULSAR_GPU_PIPELINE": "both",
    "PULSAR_GL_PBO_UPLOAD": "1",
    "PULSAR_STEREO_PAIRING_MODE": "latest",
    "PULSAR_CAMERA_FPS": "32",
    "PULSAR_CAMERA_EXPOSURE_US": "30000",
    "PULSAR_CAMERA_GAIN_DB_X10": "0",
    "PULSAR_CAMERA_AUTO_EXPOSURE": "0",
    "PULSAR_CAMERA_WHITE_BALANCE": "Manual",
    "PULSAR_CAMERA_WB_RED_X1000": "2250",
    "PULSAR_CAMERA_WB_GREEN_X1000": "1000",
    "PULSAR_CAMERA_WB_BLUE_X1000": "1730",
    "PULSAR_CAMERA_ENHANCE": "Low",
    "PULSAR_JPEG_QUALITY": "88",
}

for env_path in env_paths:
    if not env_path.exists():
        env_path.touch()

    lines = env_path.read_text(errors="replace").splitlines()
    output = []
    written = set()

    for line in lines:
        stripped = line.strip()

        if not stripped or stripped.startswith("#") or "=" not in line:
            output.append(line)
            continue

        key = line.split("=", 1)[0].strip()

        if key in settings:
            if key not in written:
                output.append(f"{key}={settings[key]}")
                written.add(key)
            continue

        output.append(line)

    missing = [key for key in settings if key not in written]

    if missing:
        output.extend(
            ["", "# Exact image authority from the known-good reference ZIP"]
        )
        output.extend(f"{key}={settings[key]}" for key in missing)

    env_path.write_text("\n".join(output).rstrip() + "\n")

print("CameraDevice profile authority and reference settings applied.")
PY_PATCH

grep -q 'PULSAR_REFERENCE_PROFILE_AUTHORITY_V2' \
    "$LOCAL_ROOT/camera/src/CameraDevice.cpp"

grep -q 'PULSAR_REFERENCE_APPLY_GUARD_V2' \
    "$LOCAL_ROOT/camera/src/CameraDevice.cpp"

echo
echo "[3/8] Validating and saving the final patch to GitHub..."

bash -n "$LOCAL_ROOT/core/scripts/start-session.sh"
git diff --check

git add \
    camera/src/CameraDevice.cpp \
    core/config/pulsar.env \
    camera/profiles/FCU22080658-reference350.txt \
    camera/profiles/FCU22080659-reference350.txt

# pulsar.local.env is committed only when it is already tracked. An ignored
# machine-local configuration is deployed to the server but is not forced into GitHub.
if git ls-files --error-unmatch core/config/pulsar.local.env >/dev/null 2>&1; then
    git add core/config/pulsar.local.env
fi

if git diff --cached --quiet; then
    echo "No new source change to commit; using the current HEAD."
else
    git commit -m "Use exact reference camera profile with low latency [$TS]"
fi

PATCH_COMMIT="$(git rev-parse HEAD)"
PATCH_TAG="pulsar-reference-image-$TS-${PATCH_COMMIT:0:12}"

git tag -f "$PATCH_TAG" "$PATCH_COMMIT"
git push origin "$GIT_BRANCH"
git push origin "refs/tags/$PATCH_TAG"

echo "GitHub patch commit: $PATCH_COMMIT"
echo "GitHub patch tag: $PATCH_TAG"

echo
echo "[4/8] Creating the deployment payload from the GitHub-saved files..."

tar -C "$LOCAL_ROOT" -czf "$PAYLOAD" \
    camera/src/CameraDevice.cpp \
    core/config/pulsar.env \
    core/config/pulsar.local.env \
    camera/profiles/FCU22080658-reference350.txt \
    camera/profiles/FCU22080659-reference350.txt

cat > /tmp/pulsar-reference-authority-remote.sh <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${PULSAR_ROOT:?}"
TS="${PULSAR_TS:?}"
PAYLOAD="${PULSAR_PAYLOAD:?}"
EXPECTED_PROFILE_SHA="${PULSAR_PROFILE_SHA:?}"

ROLLBACK_TAR="/tmp/pulsar-reference-authority-rollback-$TS.tar.gz"
STAGING="$ROOT/core/build-reference-authority-$TS"
APP_LOG="$ROOT/core/data/pulsar.log"
CURRENT_BINARY="$ROOT/core/build/pulsar-core"
OLD_BINARY="/tmp/pulsar-reference-authority-pulsar-core-$TS"

rollback() {
    code=$?
    trap - ERR
    set +e
    echo
    echo "ERROR: server update failed; restoring the temporary pre-change state..."

    if [[ -f "$ROLLBACK_TAR" ]]; then
        tar -C "$ROOT" -xzf "$ROLLBACK_TAR"
    fi

    if [[ -f "$OLD_BINARY" ]]; then
        install -m 0755 "$OLD_BINARY" "$CURRENT_BINARY"
    fi

    sudo -n systemctl restart pulsar-kiosk.service >/dev/null 2>&1 || true
    rm -rf "$STAGING"
    rm -f "$ROLLBACK_TAR" "$OLD_BINARY"
    echo "The durable backup remains in GitHub tag: ${PULSAR_BEFORE_TAG:-unknown}"
    exit "$code"
}
trap rollback ERR

for required in \
    "$ROOT/CMakeLists.txt" \
    "$ROOT/camera/src/CameraDevice.cpp" \
    "$ROOT/core/config/pulsar.local.env"
do
    [[ -e "$required" ]] || {
        echo "ERROR: missing server file: $required"
        exit 1
    }
done

mkdir -p "$ROOT/core/data"

# Temporary rollback data exists only during this run. The permanent
# checkpoint was already pushed to GitHub before deployment.
ROLLBACK_LIST=()
for item in \
    camera/src/CameraDevice.cpp \
    core/config/pulsar.env \
    core/config/pulsar.local.env \
    camera/profiles/FCU22080658-reference350.txt \
    camera/profiles/FCU22080659-reference350.txt
do
    [[ -e "$ROOT/$item" ]] && ROLLBACK_LIST+=("$item")
done

if [[ "${#ROLLBACK_LIST[@]}" -eq 0 ]]; then
    echo "ERROR: no server files were available for temporary rollback."
    exit 1
fi

tar -C "$ROOT" -czf "$ROLLBACK_TAR" "${ROLLBACK_LIST[@]}"

if [[ -x "$CURRENT_BINARY" ]]; then
    cp -a "$CURRENT_BINARY" "$OLD_BINARY"
fi

echo
echo "[5/8] Installing source and exact profiles on the server..."

tar -C "$ROOT" -xzf "$PAYLOAD"

for profile in \
    "$ROOT/camera/profiles/FCU22080658-reference350.txt" \
    "$ROOT/camera/profiles/FCU22080659-reference350.txt"
do
    actual="$(sha256sum "$profile" | awk '{print $1}')"

    if [[ "$actual" != "$EXPECTED_PROFILE_SHA" ]]; then
        echo "ERROR: server profile checksum mismatch: $profile"
        exit 1
    fi
done

grep -q 'PULSAR_REFERENCE_PROFILE_AUTHORITY_V2' \
    "$ROOT/camera/src/CameraDevice.cpp"

grep -q 'PULSAR_REFERENCE_APPLY_GUARD_V2' \
    "$ROOT/camera/src/CameraDevice.cpp"

echo
echo "[6/8] Building a separate CUDA/NPP binary while kiosk stays running..."

rm -rf "$STAGING"

cmake \
    -S "$ROOT" \
    -B "$STAGING" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.2/bin/nvcc \
    -DCMAKE_CUDA_ARCHITECTURES=86

cmake --build "$STAGING" -j"$(nproc)"

test -x "$STAGING/pulsar-core"

if ! ldd "$STAGING/pulsar-core" | grep -q 'libcudart'; then
    echo "ERROR: staged binary is not linked to CUDA."
    exit 1
fi

if ldd "$STAGING/pulsar-core" | grep -q 'not found'; then
    echo "ERROR: staged binary has a missing library."
    ldd "$STAGING/pulsar-core"
    exit 1
fi

echo
echo "[7/8] Atomically installing the binary and restarting..."

mkdir -p "$ROOT/core/build"
install -m 0755 "$STAGING/pulsar-core" "$CURRENT_BINARY"

START_LINE=0
if [[ -r "$APP_LOG" ]]; then
    START_LINE="$(wc -l < "$APP_LOG" 2>/dev/null || echo 0)"
fi

sudo -n systemctl restart pulsar-kiosk.service

for _ in $(seq 1 120); do
    NEW_LOG="$(tail -n "+$((START_LINE + 1))" "$APP_LOG" 2>/dev/null || true)"

    if systemctl is-active --quiet pulsar-kiosk.service &&
       pgrep -x pulsar-core >/dev/null 2>&1 &&
       grep -q 'FCU22080658-reference350.txt' <<<"$NEW_LOG" &&
       grep -q 'FCU22080659-reference350.txt' <<<"$NEW_LOG" &&
       grep -q 'configured sensor=4024x3036' <<<"$NEW_LOG" &&
       grep -q 'stream-buffer-mode=NewestOnly acquisition-buffers=2' \
           <<<"$NEW_LOG" &&
       grep -q 'GPU pipeline ready' <<<"$NEW_LOG"; then
        break
    fi

    sleep 1
done

sleep 12

NEW_LOG_FILE="/tmp/pulsar-reference-authority-new-$TS.log"
tail -n "+$((START_LINE + 1))" "$APP_LOG" \
    > "$NEW_LOG_FILE" 2>/dev/null || true

echo
echo "[8/8] Verification..."

echo "=== SERVICE ==="
systemctl is-active pulsar-kiosk.service
pgrep -a -x pulsar-core

echo
echo "=== PROFILE IMPORT ==="
grep -aE \
    'imported GalaxyView profile|configured sensor=|stream-buffer-mode=|GPU pipeline ready|CPU fallback' \
    "$NEW_LOG_FILE" |
    tail -n 60 || true

echo
echo "=== PERFORMANCE ==="
grep -aE \
    '(Left|Right) Camera: latency-stats pipeline=|SBS Renderer: latency-stats' \
    "$NEW_LOG_FILE" |
    tail -n 30 || true

echo
echo "=== ERRORS ==="
grep -aEi \
    'GXImportConfigFile failed|required GalaxyView profile|CPU fallback|cuda.*(error|failed)|camera.*timeout|disconnect|reset' \
    "$NEW_LOG_FILE" |
    tail -n 40 || true

systemctl is-active --quiet pulsar-kiosk.service
pgrep -x pulsar-core >/dev/null

grep -q 'FCU22080658-reference350.txt' "$NEW_LOG_FILE"
grep -q 'FCU22080659-reference350.txt' "$NEW_LOG_FILE"

if [[ "$(grep -c 'configured sensor=4024x3036' "$NEW_LOG_FILE")" -lt 2 ]]; then
    echo "ERROR: both cameras did not keep the reference full sensor geometry."
    exit 1
fi

if [[ "$(grep -c 'GPU pipeline ready' "$NEW_LOG_FILE")" -lt 2 ]]; then
    echo "ERROR: both camera CUDA pipelines are not ready."
    exit 1
fi

if [[ "$(grep -c \
    'stream-buffer-mode=NewestOnly acquisition-buffers=2' \
    "$NEW_LOG_FILE")" -lt 2 ]]; then
    echo "ERROR: low-latency stream policy is not active on both cameras."
    exit 1
fi

if grep -aEq \
    'GXImportConfigFile failed|required GalaxyView profile|CPU fallback' \
    "$NEW_LOG_FILE"; then
    echo "ERROR: reference profile or CUDA startup failed."
    exit 1
fi

rm -rf "$STAGING"
rm -f "$NEW_LOG_FILE" "$ROLLBACK_TAR" "$OLD_BINARY"
trap - ERR

echo
echo "============================================================"
echo "FINAL_STATUS=REFERENCE_IMAGE_AUTHORITY_V3_ACTIVE"
echo "Profile SHA256: $EXPECTED_PROFILE_SHA"
echo "Image owner: imported GalaxyView profile"
echo "Sensor: 4024x3036 BayerRG8"
echo "Exposure: 30000 us"
echo "Gain: 0"
echo "Black level: 4"
echo "White balance: 2.25 / 1.0 / 1.73047"
echo "Throughput: 350000000"
echo "Latency path: CUDA + NewestOnly + 2 buffers + latest"
echo "Persistent backup: GitHub tag $PULSAR_BEFORE_TAG"
echo "============================================================"
REMOTE

chmod 700 /tmp/pulsar-reference-authority-remote.sh

echo
echo "Connecting to $REMOTE_USER@$SERVER ..."
echo "رمز SSH کاربر matin را یک‌بار وارد کن."

ssh \
    -M -S "$SOCKET" \
    -o ControlPersist=300 \
    -o StrictHostKeyChecking=accept-new \
    -fnN "$REMOTE_USER@$SERVER"

scp \
    -o ControlPath="$SOCKET" \
    "$PAYLOAD" \
    "$REMOTE_USER@$SERVER:$REMOTE_PAYLOAD"

scp \
    -o ControlPath="$SOCKET" \
    /tmp/pulsar-reference-authority-remote.sh \
    "$REMOTE_USER@$SERVER:$REMOTE_SCRIPT"

set +e
ssh \
    -o ControlPath="$SOCKET" \
    "$REMOTE_USER@$SERVER" \
    "PULSAR_ROOT='$REMOTE_ROOT' \
     PULSAR_TS='$TS' \
     PULSAR_PAYLOAD='$REMOTE_PAYLOAD' \
     PULSAR_PROFILE_SHA='$EXPECTED_PROFILE_SHA' \
     PULSAR_BEFORE_TAG='$BEFORE_TAG' \
     bash '$REMOTE_SCRIPT'" \
    2>&1 | tee "$LOCAL_LOG"

STATUS=${PIPESTATUS[0]}
set -e

echo
echo "============================================================"
echo "Execution log:"
echo "$LOCAL_LOG"
echo "GitHub checkpoint tag:"
echo "$BEFORE_TAG"
echo "GitHub patch tag:"
echo "$PATCH_TAG"
echo "============================================================"

if [[ "$STATUS" -ne 0 ]]; then
    echo "اصلاح سرور ناموفق بود و سرور به وضعیت موقت قبل برگشت؛ نسخه‌ها در GitHub محفوظ هستند."
    exit "$STATUS"
fi

echo
echo "تغییرات محلی و نسخه نهایی هر دو در GitHub ذخیره شدند."
