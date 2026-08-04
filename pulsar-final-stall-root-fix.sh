#!/usr/bin/env bash
set -Eeuo pipefail

SERVER="${PULSAR_SERVER:-192.168.1.123}"
REMOTE_USER="${PULSAR_REMOTE_USER:-matin}"
REMOTE_ROOT="${PULSAR_REMOTE_ROOT:-/home/matin/Pulsar-Cpp-Core}"
LOCAL_ROOT="${PULSAR_LOCAL_ROOT:-$PWD}"
TS="$(date +%Y%m%d-%H%M%S)"
SOCKET="/tmp/pulsar-stall-v2-${USER}-$$"
LOCAL_BACKUP="$HOME/Downloads/Pulsar-Patch-Backups/stall-v2-$TS"
LOCAL_LOG="$HOME/Downloads/pulsar-stall-root-fix-v2-$TS.log"
PAYLOAD="/tmp/pulsar-stall-v2-$TS.tar.gz"
REMOTE_PAYLOAD="/tmp/pulsar-stall-v2-$TS.tar.gz"
REMOTE_SCRIPT="/tmp/pulsar-stall-v2-$TS.sh"
SUCCESS=0
LOCAL_PATCHED=0

mkdir -p "$HOME/Downloads/Pulsar-Patch-Backups"

if [[ ! -f "$LOCAL_ROOT/CMakeLists.txt" || ! -f "$LOCAL_ROOT/ui/frontend/package.json" ]]; then
  echo "ERROR: این دستور را از ریشه پروژه اجرا کن:"
  echo "  cd ~/Music/Pulsar-Cpp-Core-PreStage8-Downloaded"
  exit 1
fi

cleanup() {
  ssh -S "$SOCKET" -O exit "$REMOTE_USER@$SERVER" >/dev/null 2>&1 || true
  rm -f "$SOCKET" "$PAYLOAD"
}

restore_local() {
  [[ "$LOCAL_PATCHED" == "1" ]] || return 0
  [[ -d "$LOCAL_BACKUP/project" ]] || return 0
  echo "Restoring local project from $LOCAL_BACKUP ..."
  cp -a "$LOCAL_BACKUP/project/." "$LOCAL_ROOT/"
}

on_exit() {
  status=$?
  if [[ "$status" -ne 0 && "$SUCCESS" != "1" ]]; then
    restore_local || true
  fi
  cleanup
  exit "$status"
}
trap on_exit EXIT

FILES=(
  core/config/pulsar.local.env
  camera/src/CameraDevice.cpp
  ui/backend/src/HttpServer.cpp
  ui/frontend/src/app/App.tsx
  core/scripts/start-session.sh
  camera/profiles/FCU22080658-throughput395.txt
  camera/profiles/FCU22080659-throughput395.txt
  ui/dist
)

mkdir -p "$LOCAL_BACKUP/project"
for rel in "${FILES[@]}"; do
  if [[ -e "$LOCAL_ROOT/$rel" ]]; then
    mkdir -p "$LOCAL_BACKUP/project/$(dirname "$rel")"
    cp -a "$LOCAL_ROOT/$rel" "$LOCAL_BACKUP/project/$rel"
  fi
done
LOCAL_PATCHED=1

echo "============================================================"
echo "PULSAR STALL ROOT FIX V2"
echo "Local project: $LOCAL_ROOT"
echo "Remote project: $REMOTE_USER@$SERVER:$REMOTE_ROOT"
echo "Local backup: $LOCAL_BACKUP"
echo "============================================================"

echo
echo "[1/7] Applying durable fixes to the local project..."

python3 - "$LOCAL_ROOT" <<'PY_PATCH'
from pathlib import Path
import sys

root = Path(sys.argv[1])
env_path = root / "core/config/pulsar.local.env"
camera_path = root / "camera/src/CameraDevice.cpp"
http_path = root / "ui/backend/src/HttpServer.cpp"
app_path = root / "ui/frontend/src/app/App.tsx"
session_path = root / "core/scripts/start-session.sh"
profile_dir = root / "camera/profiles"

for path in (env_path, camera_path, http_path, app_path, session_path):
    if not path.exists():
        raise SystemExit(f"ERROR: missing file: {path}")

# Runtime settings: latest frames, no periodic topology polling, stable source FPS.
settings = {
    "PULSAR_STEREO_PAIRING_MODE": "latest",
    "PULSAR_CAMERA_FPS": "32",
    "PULSAR_DISPLAY_HOTPLUG_WATCH": "0",
    "PULSAR_AUDIO_HOTPLUG_WATCH": "0",
    "PULSAR_TOUCH_HOTPLUG_WATCH": "0",
    "PULSAR_BROWSER_GPU": "1",
    "PULSAR_GPU_PIPELINE": "both",
    "PULSAR_GL_PBO_UPLOAD": "1",
    "PULSAR_LEFT_CAMERA_SERIAL": "FCU22080658",
    "PULSAR_RIGHT_CAMERA_SERIAL": "FCU22080659",
    "PULSAR_LEFT_CAMERA_PROFILE": "camera/profiles/FCU22080658-throughput395.txt",
    "PULSAR_RIGHT_CAMERA_PROFILE": "camera/profiles/FCU22080659-throughput395.txt",
}

lines = env_path.read_text().splitlines()
out = []
written = set()
for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or "=" not in line:
        out.append(line)
        continue
    key = line.split("=", 1)[0].strip()
    if key in settings:
        if key not in written:
            out.append(f"{key}={settings[key]}")
            written.add(key)
        continue
    out.append(line)
if any(k not in written for k in settings):
    out.extend(["", "# Stable real-time latency configuration V2"])
    for key, value in settings.items():
        if key not in written:
            out.append(f"{key}={value}")
env_path.write_text("\n".join(out).rstrip() + "\n")

# Separate profiles and force latest-frame stream handling.
right_profile = profile_dir / "FCU22080659-throughput395.txt"
left_profile = profile_dir / "FCU22080658-throughput395.txt"
if not right_profile.exists():
    raise SystemExit(f"ERROR: missing profile: {right_profile}")
if not left_profile.exists():
    left_profile.write_bytes(right_profile.read_bytes())
for profile in (left_profile, right_profile):
    text = profile.read_text(errors="replace")
    text = text.replace("StreamBufferHandlingMode\tOldestFirst", "StreamBufferHandlingMode\tNewestOnly")
    profile.write_text(text)

# Correct Galaxy stream-layer handle and reduce acquisition queue depth.
text = camera_path.read_text()
marker = "PULSAR_STREAM_HANDLE_NEWEST_ONLY_V1"
if marker not in text:
    old_transfer = '''  setInt(device_, "StreamTransferSize", 64 * 1024);
  setInt(device_, "StreamTransferNumberUrb", 32);
  setBool(device_, "FrameStoreCoverActive", true);
  setEnum(device_, "CoverFrameStoreMode", "On");
'''
    new_transfer = '''  // PULSAR_STREAM_HANDLE_NEWEST_ONLY_V1
  // Stream nodes belong to GX_DS_HANDLE. Writing them through the device
  // handle silently left the SDK in OldestFirst/unchanged mode.
  GX_DS_HANDLE streamHandle = nullptr;
  const bool haveStreamHandle =
      GXGetDataStreamHandleFromDev(device_, 0, &streamHandle) == GX_STATUS_SUCCESS &&
      streamHandle != nullptr;
  GX_PORT_HANDLE streamPort = haveStreamHandle
      ? static_cast<GX_PORT_HANDLE>(streamHandle)
      : static_cast<GX_PORT_HANDLE>(device_);

  setInt(streamPort, "StreamTransferSize", 256 * 1024);
  setInt(streamPort, "StreamTransferNumberUrb", 64);
  setBool(device_, "FrameStoreCoverActive", true);
  setEnum(device_, "CoverFrameStoreMode", "On");
'''
    old_queue = '''  const char* streamBufferMode = "unchanged";
  if (setEnum(device_, "StreamBufferHandlingMode", "NewestOnly")) {
    streamBufferMode = "NewestOnly";
  } else if (setEnum(device_, "StreamBufferHandlingMode", "OldestFirstOverwrite")) {
    streamBufferMode = "OldestFirstOverwrite";
  }

  constexpr uint64_t kAcquisitionBufferCount = 4;
'''
    new_queue = '''  const char* streamBufferMode = "unchanged";
  if (setEnum(streamPort, "StreamBufferHandlingMode", "NewestOnly")) {
    streamBufferMode = "NewestOnly";
  } else if (setEnum(streamPort, "StreamBufferHandlingMode", "OldestFirstOverwrite")) {
    streamBufferMode = "OldestFirstOverwrite";
  }

  constexpr uint64_t kAcquisitionBufferCount = 2;
'''
    if old_transfer not in text or old_queue not in text:
        raise SystemExit("ERROR: CameraDevice.cpp does not match the expected source; no partial patch was written.")
    text = text.replace(old_transfer, new_transfer, 1)
    text = text.replace(old_queue, new_queue, 1)
    camera_path.write_text(text)

# Remove expensive subprocesses from the /api/state hot path and cache topology.
text = http_path.read_text()
marker = "PULSAR_STATE_FAST_CACHE_V2"
if marker not in text:
    if "#include <mutex>" not in text:
        text = text.replace("#include <map>\n", "#include <map>\n#include <mutex>\n", 1)

    old_audio = '''  for (auto& output : outputs) {
    if (const auto sinkState = readSinkState(output.sink)) {
      output.volume = std::clamp(sinkState->volume, 0, 125);
      output.muted = sinkState->muted;
    }
  }

  return outputs;
'''
    new_audio = '''  // PULSAR_STATE_FAST_CACHE_V2
  // Do not fork pactl processes for every /api/state request. State writes
  // already update volume/mute and explicit output actions still call pactl.
  return outputs;
'''
    if old_audio not in text:
        raise SystemExit("ERROR: audio state hot-path block not found.")
    text = text.replace(old_audio, new_audio, 1)

    old_name = "std::vector<DisplayPortSnapshot> readDisplayPorts() {"
    if old_name not in text:
        raise SystemExit("ERROR: readDisplayPorts function not found.")
    text = text.replace(old_name, "std::vector<DisplayPortSnapshot> readDisplayPortsUncached() {", 1)

    end_marker = '''  return ports;
}

SystemDetailsSnapshot buildSystemDetails(const std::vector<DisplayPortSnapshot>& ports) {
'''
    wrapper = '''  return ports;
}

std::vector<DisplayPortSnapshot> readDisplayPorts() {
  using Clock = std::chrono::steady_clock;
  static std::mutex cacheMutex;
  static Clock::time_point updated{};
  static std::vector<DisplayPortSnapshot> cached;
  const auto now = Clock::now();

  std::lock_guard<std::mutex> lock(cacheMutex);
  if (cached.empty() || now - updated >= std::chrono::seconds(60)) {
    cached = readDisplayPortsUncached();
    updated = now;
  }
  return cached;
}

SystemDetailsSnapshot buildSystemDetails(const std::vector<DisplayPortSnapshot>& ports) {
'''
    if end_marker not in text:
        raise SystemExit("ERROR: readDisplayPorts end marker not found.")
    text = text.replace(end_marker, wrapper, 1)

    old_journal = '''  try {
    const std::string logOutput = runCommand({"journalctl", "-u", "pulsar-kiosk.service", "-n", "200", "--no-pager"},
                                             std::chrono::seconds(5));
    details.logLines = static_cast<int>(std::count(logOutput.begin(), logOutput.end(), '\\n'));
  } catch (...) {
    details.logLines = 0;
  }
'''
    new_journal = '''  try {
    const auto logPath = dataRootPath() / "pulsar.log";
    const auto bytes = std::filesystem::exists(logPath)
        ? std::filesystem::file_size(logPath)
        : 0u;
    details.logLines = bytes == 0u ? 0 : 200;
  } catch (...) {
    details.logLines = 0;
  }
'''
    if old_journal not in text:
        raise SystemExit("ERROR: journalctl hot-path block not found.")
    text = text.replace(old_journal, new_journal, 1)

    old_details = '''std::string systemDetailsJson(const std::vector<DisplayPortSnapshot>& ports) {
  const auto details = buildSystemDetails(ports);
  std::ostringstream json;
'''
    new_details = '''std::string systemDetailsJson(const std::vector<DisplayPortSnapshot>& ports) {
  using Clock = std::chrono::steady_clock;
  static std::mutex cacheMutex;
  static Clock::time_point updated{};
  static SystemDetailsSnapshot cached;
  static bool cacheValid = false;
  SystemDetailsSnapshot details;
  const auto now = Clock::now();
  {
    std::lock_guard<std::mutex> lock(cacheMutex);
    if (!cacheValid || now - updated >= std::chrono::seconds(10)) {
      cached = buildSystemDetails(ports);
      updated = now;
      cacheValid = true;
    }
    details = cached;
  }
  std::ostringstream json;
'''
    if old_details not in text:
        raise SystemExit("ERROR: systemDetailsJson start not found.")
    text = text.replace(old_details, new_details, 1)
    http_path.write_text(text)

# Slow non-camera state polling; camera MJPEG continues independently.
app_text = app_path.read_text()
old_refresh = 'const refreshMs = activePage === "system" || activePage === "display-settings" ? 2000 : 6000;'
new_refresh = 'const refreshMs = activePage === "system" || activePage === "display-settings" ? 5000 : 15000;'
if old_refresh in app_text:
    app_text = app_text.replace(old_refresh, new_refresh, 1)
elif new_refresh not in app_text:
    raise SystemExit("ERROR: App.tsx refresh interval marker not found.")
app_path.write_text(app_text)

# Configure touch once at startup. A periodic xrandr/xinput watcher caused a
# visible freeze every two seconds and was not terminated by session cleanup.
session = session_path.read_text()
if 'touch_watch_pid=""' not in session:
    session = session.replace('audio_watch_pid=""\n', 'audio_watch_pid=""\ntouch_watch_pid=""\n', 1)
    session = session.replace(
        'kill "$audio_watch_pid" "$display_watch_pid" "$browser_pid" "$core_pid" "$openbox_pid" "$unclutter_pid" 2>/dev/null || true',
        'kill "$touch_watch_pid" "$audio_watch_pid" "$display_watch_pid" "$browser_pid" "$core_pid" "$openbox_pid" "$unclutter_pid" 2>/dev/null || true',
        1,
    )
old_touch = '"$PULSAR_ROOT/core/scripts/configure-touch.sh" --watch --interval 2 >>"$touch_log_file" 2>&1 &\n'
new_touch = '''"$PULSAR_ROOT/core/scripts/configure-touch.sh" >>"$touch_log_file" 2>&1 || true
if [[ "${PULSAR_TOUCH_HOTPLUG_WATCH:-0}" == "1" ]]; then
  "$PULSAR_ROOT/core/scripts/configure-touch.sh" --watch --interval 30 >>"$touch_log_file" 2>&1 &
  touch_watch_pid=$!
fi
'''
if old_touch in session:
    session = session.replace(old_touch, new_touch, 1)
elif new_touch not in session:
    raise SystemExit("ERROR: touch watcher start line not found.")
session_path.write_text(session)
PY_PATCH

chmod +x "$LOCAL_ROOT/core/scripts/start-session.sh"
bash -n "$LOCAL_ROOT/core/scripts/start-session.sh"

echo
echo "[2/7] Building the UI locally with the working npm installation..."
"$LOCAL_ROOT/core/scripts/build-ui.sh" 2>&1 | tee "$LOCAL_LOG"

echo
echo "[3/7] Creating a small deployment payload..."
tar -C "$LOCAL_ROOT" -czf "$PAYLOAD" \
  core/config/pulsar.local.env \
  camera/src/CameraDevice.cpp \
  ui/backend/src/HttpServer.cpp \
  ui/frontend/src/app/App.tsx \
  core/scripts/start-session.sh \
  camera/profiles/FCU22080658-throughput395.txt \
  camera/profiles/FCU22080659-throughput395.txt \
  ui/dist

cat > /tmp/pulsar-stall-v2-remote.sh <<'REMOTE_SCRIPT_BODY'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${PULSAR_ROOT:-/home/matin/Pulsar-Cpp-Core}"
TS="${PULSAR_TS:?}"
PAYLOAD="${PULSAR_PAYLOAD:?}"
BACKUP="$ROOT/.pulsar-backups/stall-root-fix-v2-$TS"
APP_LOG="$ROOT/core/data/pulsar.log"
BUILD_LOG="$ROOT/core/data/stall-root-fix-v2-build-$TS.log"
ROLLBACK_DONE=0
START_LINE=0

rollback() {
  code=$?
  trap - ERR
  set +e
  if [[ "$ROLLBACK_DONE" == "1" ]]; then
    exit "$code"
  fi
  ROLLBACK_DONE=1
  echo
  echo "ERROR: remote build/apply failed; restoring $BACKUP"
  if [[ -d "$BACKUP/project" ]]; then
    cp -a "$BACKUP/project/." "$ROOT/"
  fi
  chmod +x "$ROOT/core/scripts/start-session.sh" 2>/dev/null || true
  cd "$ROOT"
  ./run.sh build >/dev/null 2>&1 || true
  sudo -n systemctl restart pulsar-kiosk.service >/dev/null 2>&1 || true
  echo "REMOTE_ROLLBACK_COMPLETE"
  exit "$code"
}
trap rollback ERR

mkdir -p "$BACKUP/project/core/config" \
         "$BACKUP/project/camera/src" \
         "$BACKUP/project/ui/backend/src" \
         "$BACKUP/project/ui/frontend/src/app" \
         "$BACKUP/project/core/scripts" \
         "$BACKUP/project/camera/profiles" \
         "$BACKUP/project/ui"

for rel in \
  core/config/pulsar.local.env \
  camera/src/CameraDevice.cpp \
  ui/backend/src/HttpServer.cpp \
  ui/frontend/src/app/App.tsx \
  core/scripts/start-session.sh \
  camera/profiles/FCU22080658-throughput395.txt \
  camera/profiles/FCU22080659-throughput395.txt \
  ui/dist
 do
  if [[ -e "$ROOT/$rel" ]]; then
    mkdir -p "$BACKUP/project/$(dirname "$rel")"
    cp -a "$ROOT/$rel" "$BACKUP/project/$rel"
  fi
 done

[[ -r "$PAYLOAD" ]] || { echo "ERROR: missing payload $PAYLOAD"; exit 1; }
tar -xzf "$PAYLOAD" -C "$ROOT"
chmod +x "$ROOT/core/scripts/start-session.sh"
bash -n "$ROOT/core/scripts/start-session.sh"

if [[ -r "$APP_LOG" ]]; then
  START_LINE="$(wc -l < "$APP_LOG" || echo 0)"
fi

echo "[4/7] Clean C++ build on server (UI was already built locally)..."
rm -rf "$ROOT/core/build"
cd "$ROOT"
./run.sh build 2>&1 | tee "$BUILD_LOG"

if ! ldd "$ROOT/core/build/pulsar-core" | grep -q 'libcudart'; then
  echo "ERROR: final binary is not linked to CUDA."
  exit 1
fi
if ldd "$ROOT/core/build/pulsar-core" | grep -q 'not found'; then
  echo "ERROR: a runtime library is missing."
  ldd "$ROOT/core/build/pulsar-core" | grep 'not found' || true
  exit 1
fi

echo "[5/7] Restarting kiosk..."
sudo -n systemctl restart pulsar-kiosk.service

for _ in $(seq 1 120); do
  if systemctl is-active --quiet pulsar-kiosk.service && \
     pgrep -x pulsar-core >/dev/null 2>&1 && \
     tail -n "+$((START_LINE + 1))" "$APP_LOG" 2>/dev/null | \
       grep -q 'GPU pipeline ready'; then
    break
  fi
  sleep 1
done
sleep 20

NEW_LOG="$(tail -n "+$((START_LINE + 1))" "$APP_LOG" 2>/dev/null || true)"

echo "[6/7] Runtime verification..."
echo "=== STARTUP ==="
printf '%s\n' "$NEW_LOG" | grep -E 'stream-buffer-mode=|configured sensor=|GPU pipeline ready|stereo-pairing-mode=' | tail -n 30 || true

echo "=== CAMERA ==="
printf '%s\n' "$NEW_LOG" | grep -E '(Left|Right) Camera: latency-stats pipeline=' | tail -n 16 || true

echo "=== RENDERER ==="
printf '%s\n' "$NEW_LOG" | grep -E 'SBS Renderer: latency-stats' | tail -n 12 || true

echo "=== STATE API ==="
for _ in $(seq 1 10); do
  curl -sS --max-time 4 -o /dev/null -w 'state_total=%{time_total}\n' http://127.0.0.1:4173/api/state || true
  sleep .2
done

echo "=== PERIODIC WATCHERS ==="
pgrep -a -f 'configure-touch.sh.*--watch|watch_display_topology|watch_audio_topology' || true

echo "=== PROCESS LOAD ==="
ps -eo pid,pcpu,pmem,rss,comm,args --sort=-pcpu | grep -E 'pulsar-core|Xorg|chrome' | head -n 20 || true

echo "[7/7] Final checks..."
systemctl is-active --quiet pulsar-kiosk.service
pgrep -x pulsar-core >/dev/null
printf '%s\n' "$NEW_LOG" | grep -q 'GPU pipeline ready'
printf '%s\n' "$NEW_LOG" | grep -q 'stereo-pairing-mode=latest-zero-hold'

trap - ERR

echo "============================================================"
echo "FINAL_STATUS=STALL_ROOT_FIX_V2_APPLIED"
echo "Remote backup: $BACKUP"
echo "Build log: $BUILD_LOG"
echo "============================================================"
REMOTE_SCRIPT_BODY

chmod 700 /tmp/pulsar-stall-v2-remote.sh

echo
echo "[4/7] Connecting to $REMOTE_USER@$SERVER..."
echo "رمز SSH کاربر matin را یک‌بار وارد کن."
ssh -M -S "$SOCKET" \
  -o ControlPersist=300 \
  -o StrictHostKeyChecking=accept-new \
  -fnN "$REMOTE_USER@$SERVER"

scp -o ControlPath="$SOCKET" "$PAYLOAD" "$REMOTE_USER@$SERVER:$REMOTE_PAYLOAD"
scp -o ControlPath="$SOCKET" /tmp/pulsar-stall-v2-remote.sh "$REMOTE_USER@$SERVER:$REMOTE_SCRIPT"

echo
echo "[5/7] Applying and building on server..."
set +e
ssh -o ControlPath="$SOCKET" "$REMOTE_USER@$SERVER" \
  "PULSAR_ROOT='$REMOTE_ROOT' PULSAR_TS='$TS' PULSAR_PAYLOAD='$REMOTE_PAYLOAD' bash '$REMOTE_SCRIPT'" \
  2>&1 | tee -a "$LOCAL_LOG"
STATUS=${PIPESTATUS[0]}
set -e

if [[ "$STATUS" -ne 0 ]]; then
  echo "Remote apply failed. Both remote and local sources are being restored."
  exit "$STATUS"
fi

SUCCESS=1
LOCAL_PATCHED=0

echo
echo "============================================================"
echo "FINAL_STATUS=STALL_ROOT_FIX_V2_APPLIED"
echo "Local project was updated permanently."
echo "Local backup: $LOCAL_BACKUP"
echo "Report: $LOCAL_LOG"
echo "============================================================"
