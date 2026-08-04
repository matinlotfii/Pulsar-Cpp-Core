#!/usr/bin/env bash
set -Eeuo pipefail

cat > /tmp/pulsar-realtime-root-fix-remote.sh <<'__PULSAR_REMOTE_PAYLOAD_EOF__'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/home/matin/Pulsar-Cpp-Core"
ENV_FILE="$ROOT/core/config/pulsar.local.env"
APP_LOG="$ROOT/core/data/pulsar.log"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="$ROOT/.pulsar-backups/realtime-root-fix-$TS"
REPORT="$HOME/pulsar-realtime-root-fix-$TS.log"

exec > >(tee "$REPORT") 2>&1

fail() {
  echo "FINAL_STATUS=FAILED"
  echo "ERROR: $*"
  exit 1
}

[[ "$(id -un)" == "matin" ]] || fail "remote script must run as matin"
[[ -d "$ROOT" ]] || fail "project not found: $ROOT"

for command in python3 npm cmake grep sed git curl nvidia-smi; do
  command -v "$command" >/dev/null 2>&1 || fail "$command is not installed"
done

mkdir -p "$BACKUP" "$ROOT/core/data"
for file in \
  camera/src/CameraDevice.cpp \
  camera/src/SbsRenderer.cpp \
  ui/frontend/src/app/camera-stream.tsx \
  ui/frontend/src/app/App.tsx \
  core/config/pulsar.local.env; do
  [[ -e "$ROOT/$file" ]] && cp -a "$ROOT/$file" "$BACKUP/$(basename "$file")"
done
cp -a "$ROOT/camera/profiles" "$BACKUP/profiles" 2>/dev/null || true
cp -a "$APP_LOG" "$BACKUP/pulsar-before.log" 2>/dev/null || true

echo "============================================================"
echo "PULSAR REALTIME ROOT FIX"
echo "Server: $(hostname)"
echo "Backup: $BACKUP"
echo "Report: $REPORT"
echo "============================================================"

echo
echo "[1/8] Stopping kiosk cleanly..."
if ! sudo -n systemctl stop pulsar-kiosk.service; then
  fail "could not stop pulsar-kiosk.service without a sudo prompt"
fi
pkill -TERM -x pulsar-core 2>/dev/null || true
sleep 2

echo
echo "[2/8] Patching C++ preview latency and duplicate rendering..."

python3 - "$ROOT" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])

# ------------------------------------------------------------------
# Camera preview: latest-frame JPEG, configurable dimensions, no
# forced one-frame delay, and an always-on low-latency snapshot mode.
# ------------------------------------------------------------------
path = root / "camera/src/CameraDevice.cpp"
text = path.read_text()
start_marker = "void CameraDevice::previewLoop() {"
end_marker = "\nbool CameraDevice::connect() {"
start = text.find(start_marker)
end = text.find(end_marker, start)
if start < 0 or end < 0:
    raise SystemExit("CameraDevice::previewLoop boundaries were not found")

preview_loop = r'''void CameraDevice::previewLoop() {
  // PULSAR_REALTIME_PREVIEW_V2
  pthread_setname_np(pthread_self(), slot_ == 0 ? "pulsar-jpg-l" : "pulsar-jpg-r");
  bestEffortRealtime(-4, 10);

  const int previewWidth = envInt("PULSAR_PREVIEW_WIDTH", 768, 320, 1920);
  const int previewHeight = envInt("PULSAR_PREVIEW_HEIGHT", 432, 180, 1080);
  const bool previewAlwaysOn = envEnabled("PULSAR_PREVIEW_ALWAYS_ON", false);
  const auto interval = std::chrono::microseconds(
      1'000'000 / std::max(previewFps_, 1));
  auto next = std::chrono::steady_clock::now();
  uint64_t encodedId = 0;

  while (running_) {
    {
      std::unique_lock<std::mutex> lock(previewMutex_);
      previewCv_.wait(lock, [&] {
        const bool demanded =
            previewAlwaysOn || previewDemand_ == nullptr || previewDemand_();
        return !running_ ||
               (demanded && previewPending_ &&
                previewPending_->id != encodedId);
      });
    }
    if (!running_) break;

    const bool demanded =
        previewAlwaysOn || previewDemand_ == nullptr || previewDemand_();
    if (!demanded) {
      std::lock_guard<std::mutex> lock(previewMutex_);
      lastJpeg_.reset();
      continue;
    }

    std::this_thread::sleep_until(next);
    if (!running_) break;

    std::shared_ptr<const Frame> frame;
    {
      std::lock_guard<std::mutex> lock(previewMutex_);
      frame = previewPending_;
    }
    if (!frame || !frame->rgb || frame->rgb->empty()) continue;

    uint32_t jpegWidth = frame->width;
    uint32_t jpegHeight = frame->height;
    const uint8_t* jpegData = frame->rgb->data();
    const double jpegScale = std::min({
        1.0,
        static_cast<double>(previewWidth) /
            std::max<uint32_t>(1, frame->width),
        static_cast<double>(previewHeight) /
            std::max<uint32_t>(1, frame->height)});

    if (jpegScale < 0.999) {
      jpegWidth = std::max<uint32_t>(
          1, static_cast<uint32_t>(std::lround(frame->width * jpegScale)));
      jpegHeight = std::max<uint32_t>(
          1, static_cast<uint32_t>(std::lround(frame->height * jpegScale)));
      resizeRgbBilinearInto(
          frame->rgb->data(), frame->width, frame->height,
          jpegWidth, jpegHeight, previewResized_);
      jpegData = previewResized_.data();
    }

    auto jpeg = std::make_shared<std::vector<uint8_t>>(
        encodeJpeg(jpegData, jpegWidth, jpegHeight, jpegQuality_));
    {
      std::lock_guard<std::mutex> lock(previewMutex_);
      lastJpeg_ = jpeg;
    }

    // Attach the encoded preview to the same RGB frame whenever possible.
    // The previous implementation attached it only to a later frame and
    // therefore added one full camera-frame of UI latency.
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (status_.frame && status_.frame->id == frame->id) {
        auto updated = std::make_shared<Frame>(*status_.frame);
        updated->jpeg = jpeg;
        status_.frame = std::move(updated);
      }
    }
    frameCv_.notify_all();

    encodedId = frame->id;
    next += interval;
    const auto now = std::chrono::steady_clock::now();
    if (next < now) next = now + interval;
  }
}
'''
text = text[:start] + preview_loop + text[end:]

# Keep the Galaxy host queue minimal. The processing loop still drains every
# available SDK buffer and selects only the newest frame.
text = re.sub(
    r"constexpr uint64_t kAcquisitionBufferCount = [0-9]+;\n"
    r"(\s*if \(GXSetAcqusitionBufferNumber)",
    r"constexpr uint64_t kAcquisitionBufferCount = 2;\n\1",
    text,
    count=1,
)
path.write_text(text)

# ------------------------------------------------------------------
# Renderer: XRandR already mirrors the auxiliary physical output. Do
# not build/present a second SDL target unless explicitly requested.
# ------------------------------------------------------------------
path = root / "camera/src/SbsRenderer.cpp"
text = path.read_text()
if "PULSAR_RENDER_AUX_TARGETS" not in text:
    old = '''  std::vector<RenderTarget> auxTargets;
  const auto auxOutputs = splitList(envString("PULSAR_AUX_OUTPUTS", ""), ',');'''
    new = '''  std::vector<RenderTarget> auxTargets;
  const auto configuredAuxOutputs =
      splitList(envString("PULSAR_AUX_OUTPUTS", ""), ',');
  const bool renderAuxTargets =
      envEnabled("PULSAR_RENDER_AUX_TARGETS", false);
  const auto auxOutputs = renderAuxTargets
                              ? configuredAuxOutputs
                              : std::vector<std::string>{};
  if (!renderAuxTargets && !configuredAuxOutputs.empty()) {
    std::cerr << "SBS Renderer: mirrored auxiliary outputs are handled by XRandR; "
                 "duplicate SDL render targets disabled\\n";
  }'''
    if old not in text:
        raise SystemExit("SbsRenderer auxiliary target block was not found")
    text = text.replace(old, new, 1)
path.write_text(text)
PY

echo
echo "[3/8] Replacing buffered MJPEG UI with latest-frame GPU canvas..."

python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
path = root / "ui/frontend/src/app/camera-stream.tsx"
text = path.read_text()
start = text.find("function CameraLiveView({")
end = text.find("\nexport function MedicalView({", start)
if start < 0 or end < 0:
    raise SystemExit("CameraLiveView boundaries were not found")

component = r'''function CameraLiveView({
  cameraIndex,
  label,
  alignOffset
}: {
  cameraIndex: 0 | 1;
  label: string;
  alignOffset?: StereoAutoAlignState;
}) {
  // PULSAR_LATEST_FRAME_CANVAS_V2
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const liveRef = useRef(false);
  const [streamStatus, setStreamStatus] = useState<CameraStreamStatus>("connecting");
  const isCalibratedFeed = Boolean(alignOffset?.enabled && alignOffset.samples > 0);
  const alignStyle = cameraAlignStyle(cameraIndex, alignOffset);

  useEffect(() => {
    let cancelled = false;
    let failures = 0;
    let sequence = 0;
    const controller = new AbortController();
    const frameIntervalMs = 1000 / 30;
    const canvas = canvasRef.current;
    const bitmapContext = canvas?.getContext("bitmaprenderer") ?? null;
    const context2d = bitmapContext
      ? null
      : canvas?.getContext("2d", { alpha: false }) ?? null;

    const sleep = (milliseconds: number) =>
      new Promise<void>((resolve) =>
        window.setTimeout(resolve, milliseconds));

    const drawFrame = async (blob: Blob) => {
      const bitmap = await createImageBitmap(blob);
      if (cancelled || !canvasRef.current) {
        bitmap.close();
        return;
      }

      const target = canvasRef.current;
      if (target.width !== bitmap.width || target.height !== bitmap.height) {
        target.width = bitmap.width;
        target.height = bitmap.height;
      }

      if (bitmapContext) {
        bitmapContext.transferFromImageBitmap(bitmap);
      } else if (context2d) {
        context2d.drawImage(bitmap, 0, 0, target.width, target.height);
        bitmap.close();
      } else {
        bitmap.close();
        throw new Error("Canvas rendering is unavailable.");
      }
    };

    const pumpLatestFrames = async () => {
      while (!cancelled) {
        const startedAt = window.performance.now();
        try {
          const response = await fetch(
            `${cameraServiceBaseUrl()}/camera/${cameraIndex}/frame.jpg?v=${sequence++}`,
            {
              cache: "no-store",
              headers: { Accept: "image/jpeg" },
              signal: controller.signal
            }
          );
          if (!response.ok) {
            throw new Error(`Camera frame request failed: ${response.status}`);
          }
          const blob = await response.blob();
          if (!blob.type.startsWith("image/")) {
            throw new Error("Camera response is not an image.");
          }
          await drawFrame(blob);

          failures = 0;
          if (!liveRef.current) {
            liveRef.current = true;
            setStreamStatus("live");
          }
        } catch {
          if (cancelled || controller.signal.aborted) break;
          failures += 1;
          if (failures >= 3 && liveRef.current) {
            liveRef.current = false;
            setStreamStatus("offline");
          } else if (!liveRef.current) {
            setStreamStatus(failures >= 3 ? "offline" : "connecting");
          }
          await sleep(Math.min(1000, 120 * failures));
          continue;
        }

        const elapsed = window.performance.now() - startedAt;
        if (elapsed < frameIntervalMs) {
          await sleep(frameIntervalMs - elapsed);
        }
      }
    };

    void pumpLatestFrames();
    return () => {
      cancelled = true;
      controller.abort();
      liveRef.current = false;
    };
  }, [cameraIndex]);

  return (
    <div className={`medical-texture is-live-stream camera-stream-${streamStatus} ${isCalibratedFeed ? "is-calibrated-feed" : ""}`}>
      <canvas
        ref={canvasRef}
        className="camera-live-image is-visible"
        style={alignStyle}
        role="img"
        aria-label={`${label} live camera stream`}
      />
      {streamStatus === "offline" || (!liveRef.current && streamStatus !== "live") ? (
        <div className="camera-disconnect-panel" role="status" aria-live="polite">
          <div className="camera-disconnect-copy">
            <strong>{streamStatus === "offline" ? `${label} disconnected` : `Connecting ${label.toLowerCase()}`}</strong>
            <span>{streamStatus === "offline" ? "No live image is available." : "Waiting for live image."}</span>
          </div>
        </div>
      ) : null}
      <span className="vessel v1" />
      <span className="vessel v2" />
      <span className="vessel v3" />
      <span className="vessel v4" />
      {streamStatus === "live" ? (
        <>
          <span className="view-label is-live">● LIVE</span>
          <span className="fullscreen-cue">⌖</span>
        </>
      ) : null}
    </div>
  );
}
'''
path.write_text(text[:start] + component + text[end:])

# Avoid overlapping expensive auto-align requests and do not poll rapidly while
# auto alignment is disabled.
path = root / "ui/frontend/src/app/App.tsx"
text = path.read_text()
old = '''  useEffect(() => {
    let alive = true;
    const syncAutoAlign = async () => {
      try {
        const state = await requestStereoAutoAlign();
        if (alive) setAutoAlign(state);
      } catch {
      }
    };
    void syncAutoAlign();
    const timer = window.setInterval(syncAutoAlign, autoAlign.active ? 180 : 900);
    return () => {
      alive = false;
      window.clearInterval(timer);
    };
  }, [autoAlign.active]);'''
new = '''  useEffect(() => {
    let alive = true;
    let inFlight = false;
    const syncAutoAlign = async () => {
      if (inFlight) return;
      inFlight = true;
      try {
        const state = await requestStereoAutoAlign();
        if (alive) setAutoAlign(state);
      } catch {
      } finally {
        inFlight = false;
      }
    };
    void syncAutoAlign();
    const refreshMs = autoAlign.active ? 300 : autoAlign.enabled ? 1500 : 5000;
    const timer = window.setInterval(syncAutoAlign, refreshMs);
    return () => {
      alive = false;
      window.clearInterval(timer);
    };
  }, [autoAlign.active, autoAlign.enabled]);'''
if old in text:
    text = text.replace(old, new, 1)
elif "let inFlight = false;" not in text:
    raise SystemExit("App auto-align polling block was not found")
path.write_text(text)
PY

echo
echo "[4/8] Applying stable low-latency runtime settings..."

touch "$ENV_FILE"
python3 - "$ENV_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
settings = {
    # The cameras currently deliver about 32.5 unique frames/s. A stable 30 fps
    # cadence maps exactly onto the 60 Hz display and avoids uneven 32-to-60
    # frame repetition while preserving low latency.
    "PULSAR_CAMERA_FPS": "30",
    "PULSAR_PREVIEW_FPS": "30",
    "PULSAR_PREVIEW_ALWAYS_ON": "1",
    "PULSAR_PREVIEW_WIDTH": "768",
    "PULSAR_PREVIEW_HEIGHT": "432",
    "PULSAR_JPEG_QUALITY": "72",
    "PULSAR_GPU_PIPELINE": "both",
    "PULSAR_CORE_NVIDIA_OFFLOAD": "1",
    "PULSAR_GL_PBO_UPLOAD": "1",
    "PULSAR_SBS_PRESENT_VSYNC": "1",
    "PULSAR_STEREO_PAIRING_MODE": "latest",
    "PULSAR_RENDER_AUX_TARGETS": "0",
    "PULSAR_BROWSER_GPU": "1",
    "PULSAR_CAMERA_EXPOSURE_US": "12000",
    "PULSAR_CAMERA_SENSOR_SCALE": "1",
    "PULSAR_CAMERA_MAX_WIDTH": "1920",
    "PULSAR_CAMERA_MAX_HEIGHT": "1080",
}

lines = path.read_text().splitlines() if path.exists() else []
result = []
seen = set()
for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or "=" not in line:
        result.append(line)
        continue
    key = line.split("=", 1)[0].strip()
    if key in settings:
        if key not in seen:
            result.append(f"{key}={settings[key]}")
            seen.add(key)
        continue
    result.append(line)

missing = [key for key in settings if key not in seen]
if missing:
    result.extend(["", "# Realtime root fix", *[f"{k}={settings[k]}" for k in missing]])
path.write_text("\n".join(result).rstrip() + "\n")
PY

grep -E '^(PULSAR_(CAMERA_FPS|PREVIEW_FPS|PREVIEW_ALWAYS_ON|PREVIEW_WIDTH|PREVIEW_HEIGHT|JPEG_QUALITY|GPU_PIPELINE|CORE_NVIDIA_OFFLOAD|GL_PBO_UPLOAD|SBS_PRESENT_VSYNC|STEREO_PAIRING_MODE|RENDER_AUX_TARGETS|BROWSER_GPU))=' "$ENV_FILE"

echo
echo "[5/8] Synchronizing camera profiles to stable 30 fps..."
python3 - "$ROOT/camera/profiles" <<'PY'
from pathlib import Path
import re
import sys

profiles = Path(sys.argv[1])
values = {
    "Width": "1920",
    "Height": "1080",
    "BinningHorizontal": "1",
    "BinningVertical": "1",
    "DecimationHorizontal": "1",
    "DecimationVertical": "1",
    "AcquisitionFrameRateMode": "On",
    "AcquisitionFrameRate": "30",
    "ExposureTime": "12000",
    "TriggerMode": "Off",
    "StreamBufferHandlingMode": "NewestOnly",
}

paths = [
    profiles / "FCU22080658-throughput395.txt",
    profiles / "FCU22080659-throughput395.txt",
]
for path in paths:
    if not path.exists():
        raise SystemExit(f"profile not found: {path}")
    output = []
    found = set()
    for line in path.read_text(errors="replace").splitlines():
        match = re.match(r"^([A-Za-z0-9_]+)([ \t]+)(.*)$", line)
        if match and match.group(1) in values:
            key = match.group(1)
            output.append(f"{key}\t{values[key]}")
            found.add(key)
        else:
            output.append(line)
    for key, value in values.items():
        if key not in found:
            output.append(f"{key}\t{value}")
    path.write_text("\n".join(output) + "\n")
    print(f"updated {path.name}")
PY

echo
echo "[6/8] Building UI and CUDA C++ core..."
export PATH="/usr/local/cuda-13.2/bin:$PATH"
export LD_LIBRARY_PATH="/usr/local/cuda-13.2/lib64:${LD_LIBRARY_PATH:-}"

bash "$ROOT/core/scripts/build-ui.sh"

CMAKE_LOG="$ROOT/core/data/realtime-cmake-$TS.log"
cmake \
  -S "$ROOT" \
  -B "$ROOT/core/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.2/bin/nvcc \
  -DCMAKE_CUDA_ARCHITECTURES=86 \
  2>&1 | tee "$CMAKE_LOG"

grep -q 'Pulsar CUDA/NPP pipeline: enabled' "$CMAKE_LOG" || \
  fail "CMake did not enable CUDA/NPP"

cmake --build "$ROOT/core/build" --parallel "$(nproc)"

ldd "$ROOT/core/build/pulsar-core" | grep -q 'libcudart' || \
  fail "final binary is not linked to CUDA"

# Force Chrome to load the newly built UI rather than an old cached bundle.
rm -rf \
  "$ROOT/core/data/browser-profile/Default/Cache" \
  "$ROOT/core/data/browser-profile/Default/Code Cache" \
  "$ROOT/core/data/browser-profile/ShaderCache" \
  "$ROOT/core/data/browser-profile/GPUCache" 2>/dev/null || true

echo
echo "[7/8] Starting kiosk and waiting for steady-state samples..."
: > "$APP_LOG"
sudo -n systemctl restart pulsar-kiosk.service

for _ in $(seq 1 120); do
  if systemctl is-active --quiet pulsar-kiosk.service && \
     pgrep -x pulsar-core >/dev/null 2>&1 && \
     grep -aEq '(Left|Right) Camera: latency-stats pipeline=' "$APP_LOG" 2>/dev/null; then
    break
  fi
  sleep 1
done
sleep 14

echo
echo "[8/8] Verifying camera, renderer, UI snapshots and GPU..."

echo "=== SERVICE ==="
systemctl --no-pager --full status pulsar-kiosk.service | head -40 || true

echo
echo "=== GPU ==="
nvidia-smi --query-gpu=name,pstate,temperature.gpu,utilization.gpu,memory.used,clocks.current.graphics,power.draw --format=csv || true

echo
echo "=== CAMERA STARTUP ==="
grep -aE 'configured sensor=|stream-buffer-mode=|GPU pipeline ready|CPU fallback|GPU pipeline initialization failed' "$APP_LOG" | tail -30 || true

echo
echo "=== CAMERA PERFORMANCE ==="
grep -aE '(Left|Right) Camera: latency-stats pipeline=' "$APP_LOG" | tail -20 || true

echo
echo "=== RENDER PERFORMANCE ==="
grep -aE 'SBS Renderer: latency-stats|duplicate SDL render targets disabled' "$APP_LOG" | tail -14 || true

echo
echo "=== UI LATEST-FRAME ENDPOINT TEST ==="
python3 - <<'PY'
import statistics
import time
import urllib.request

for camera in (0, 1):
    samples = []
    sizes = []
    for index in range(30):
        started = time.perf_counter()
        with urllib.request.urlopen(
            f"http://127.0.0.1:4173/camera/{camera}/frame.jpg?v={time.time_ns()}",
            timeout=2,
        ) as response:
            payload = response.read()
        samples.append((time.perf_counter() - started) * 1000.0)
        sizes.append(len(payload))
        time.sleep(1 / 30)
    ordered = sorted(samples)
    p95 = ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))]
    print(
        f"camera={camera} snapshot-mean-ms={statistics.mean(samples):.2f} "
        f"snapshot-p95-ms={p95:.2f} jpeg-mean-kib={statistics.mean(sizes)/1024:.1f}"
    )
PY

echo
echo "=== ERRORS ==="
grep -aEi 'cannot open display|driver shutting down|CPU fallback|cuda.*failed|camera.*failed|timeout|disconnect|reset|xid' "$APP_LOG" | tail -60 || true

echo
echo "=== AUTOMATIC RESULT ==="
if ! systemctl is-active --quiet pulsar-kiosk.service; then
  fail "pulsar-kiosk.service is not active"
fi
if ! pgrep -x pulsar-core >/dev/null 2>&1; then
  fail "pulsar-core is not running"
fi
if ! grep -aE '(Left|Right) Camera: latency-stats pipeline=gpu' "$APP_LOG" | tail -8 | grep -q .; then
  fail "steady GPU camera samples were not found"
fi
if grep -aEq 'CPU fallback|GPU pipeline initialization failed' "$APP_LOG"; then
  fail "GPU fallback was detected"
fi
if ! grep -aEq 'duplicate SDL render targets disabled' "$APP_LOG"; then
  fail "duplicate auxiliary renderer was not disabled"
fi

echo "FINAL_STATUS=RUNNING_REALTIME_GPU"
echo "Backup: $BACKUP"
echo "Report: $REPORT"

__PULSAR_REMOTE_PAYLOAD_EOF__

chmod 700 /tmp/pulsar-realtime-root-fix-remote.sh


SERVER="192.168.1.123"
REMOTE_USER="matin"
REMOTE_SCRIPT="/tmp/pulsar-realtime-root-fix-remote.sh"
LOCAL_SOURCE="/tmp/pulsar-realtime-root-fix-remote.sh"
TS="$(date +%Y%m%d-%H%M%S)"
DOWNLOAD_DIR="$HOME/Downloads"
LOCAL_LOG="$DOWNLOAD_DIR/pulsar-realtime-root-fix-$TS.log"
SOCKET="/tmp/pulsar-realtime-ssh-${USER}-$$"

mkdir -p "$DOWNLOAD_DIR"

if [[ "$(hostname -s)" == "pulsar" || "$(whoami)" == "matin" ]]; then
  echo "ERROR: این دستور باید روی amin@localhost اجرا شود. ابتدا exit بزن."
  exit 1
fi

[[ -s "$LOCAL_SOURCE" ]] || {
  echo "ERROR: remote repair script is missing: $LOCAL_SOURCE"
  exit 1
}

cleanup() {
  ssh -S "$SOCKET" -O exit "$REMOTE_USER@$SERVER" >/dev/null 2>&1 || true
  rm -f "$SOCKET"
}
trap cleanup EXIT

echo "اتصال به $REMOTE_USER@$SERVER ..."
echo "رمز SSH کاربر matin را فقط یک‌بار وارد کن."

ssh \
  -M \
  -S "$SOCKET" \
  -o ControlPersist=600 \
  -o StrictHostKeyChecking=accept-new \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=4 \
  -fnN \
  "$REMOTE_USER@$SERVER"

scp \
  -o ControlPath="$SOCKET" \
  "$LOCAL_SOURCE" \
  "$REMOTE_USER@$SERVER:$REMOTE_SCRIPT"

set +e
ssh \
  -tt \
  -o ControlPath="$SOCKET" \
  "$REMOTE_USER@$SERVER" \
  "chmod 700 '$REMOTE_SCRIPT' && bash '$REMOTE_SCRIPT'" 2>&1 | tee "$LOCAL_LOG"
STATUS=${PIPESTATUS[0]}
set -e

echo
echo "============================================================"
echo "گزارش روی سیستم خودت ذخیره شد:"
echo "$LOCAL_LOG"
echo "============================================================"

if [[ "$STATUS" -ne 0 ]]; then
  echo "اصلاح کامل نشده؛ همین فایل را آپلود کن."
  exit "$STATUS"
fi

if ! grep -q 'FINAL_STATUS=RUNNING_REALTIME_GPU' "$LOCAL_LOG"; then
  echo "پایان اجرا ثبت شد ولی نتیجه نهایی تأیید نشد؛ همین فایل را آپلود کن."
  exit 1
fi

echo "برنامه با مسیر کم‌تأخیر GPU اجرا شد."
