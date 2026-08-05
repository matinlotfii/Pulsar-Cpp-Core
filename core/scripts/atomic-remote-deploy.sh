#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SERVER="${PULSAR_SERVER:-192.168.1.123}"
REMOTE_USER="${PULSAR_REMOTE_USER:-matin}"
REMOTE_ROOT="${PULSAR_REMOTE_ROOT:-/home/matin/Pulsar-Cpp-Core}"
REMOTE_SERVICE="${PULSAR_REMOTE_SERVICE:-pulsar-kiosk.service}"
TS="$(date +%Y%m%d-%H%M%S)"
SOCKET="/tmp/pulsar-v8-deploy-${USER}-$$"
ARCHIVE="/tmp/pulsar-latest-v8-$TS.tar.gz"
REMOTE_ARCHIVE="/tmp/pulsar-latest-v8-$TS.tar.gz"
REMOTE_APPLY="/tmp/pulsar-atomic-v8-$TS.sh"
LOCAL_LOG="$HOME/Downloads/pulsar-run-v8-$TS.log"

mkdir -p "$HOME/Downloads"
cleanup() {
  ssh -S "$SOCKET" -O exit "$REMOTE_USER@$SERVER" >/dev/null 2>&1 || true
  rm -f "$SOCKET" "$ARCHIVE"
}
trap cleanup EXIT
fail() { echo "ERROR: $*" >&2; exit 1; }

for command in ssh scp tar; do
  command -v "$command" >/dev/null 2>&1 || fail "$command نصب نیست."
done
[[ -f "$ROOT/CMakeLists.txt" ]] || fail "ریشه پروژه پیدا نشد."

ui_needs_build() {
  [[ -f "$ROOT/ui/dist/index.html" ]] || return 0
  find "$ROOT/ui/frontend/src" "$ROOT/ui/frontend/public" \
       "$ROOT/ui/frontend/index.html" "$ROOT/ui/frontend/package.json" \
       -type f -newer "$ROOT/ui/dist/index.html" -print -quit 2>/dev/null | grep -q .
}
if ui_needs_build; then
  command -v npm >/dev/null 2>&1 || fail "UI تغییر کرده ولی npm روی سیستم محلی پیدا نشد."
  echo "[LOCAL] Building latest UI..."
  "$ROOT/core/scripts/build-ui.sh"
fi

for script in "$ROOT/run.sh" "$ROOT/core/scripts/"*.sh; do bash -n "$script"; done

echo "[LOCAL] Packing the exact latest project..."
tar -C "$ROOT" -czf "$ARCHIVE" \
  --exclude='.git' --exclude='.dev-sync' --exclude='.codex-tmp' \
  --exclude='.pulsar-backups' --exclude='core/build' --exclude='core/build-*' \
  --exclude='core/data' --exclude='node_modules' --exclude='ui/frontend/node_modules' \
  --exclude='ui/frontend/dist' --exclude='*.zip' --exclude='*.tar.gz' --exclude='*.log' .

cat > /tmp/pulsar-atomic-v8-remote.sh <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="${PULSAR_ROOT:?}"
ARCHIVE="${PULSAR_ARCHIVE:?}"
SERVICE="${PULSAR_SERVICE:?}"
TS="${PULSAR_TS:?}"
STAGE="/tmp/pulsar-v8-deploy-$TS"
PROJECT="$STAGE/project"
BUILD="$STAGE/build"
APP_LOG="$ROOT/core/data/pulsar.log"
PID_FILE="$ROOT/core/data/pulsar.pid"
REQUEST_FILE="$ROOT/core/data/restart-core.request"
CURRENT_BINARY="$ROOT/core/build/pulsar-core"
OLD_BINARY="/tmp/pulsar-core-v8-old-$TS"
OLD_FILES="/tmp/pulsar-v8-old-files-$TS.tar.gz"
STATE_DIR="$ROOT/core/data/deploy-v8"

cleanup() { rm -rf "$STAGE"; rm -f "$ARCHIVE" "$OLD_BINARY" "$OLD_FILES"; }
trap cleanup EXIT
mkdir -p "$PROJECT" "$STATE_DIR" "$ROOT/core/build" "$ROOT/core/data"
tar -C "$PROJECT" -xzf "$ARCHIVE"

for required in \
  CMakeLists.txt \
  camera/src/CameraDevice.cpp \
  camera/src/GpuBayerPipeline.cu \
  camera/src/SbsRenderer.cpp \
  camera/include/pulsar/camera/SdlMinimal.hpp \
  core/include/pulsar/core/AppState.hpp \
  ui/backend/src/HttpServer.cpp \
  core/scripts/configure-displays.sh \
  core/scripts/display-hotplug-watch.sh \
  core/scripts/restart-browser-live.sh \
  core/scripts/realtime-20s-diagnose.sh \
  core/scripts/start-session.sh; do
  [[ -f "$PROJECT/$required" ]] || { echo "ERROR: payload missing $required"; exit 1; }
done
find "$PROJECT/core/scripts" -maxdepth 1 -type f -name '*.sh' -exec bash -n {} \;

audit_hash() {
  local base="$1"; shift
  (cd "$base" && find "$@" -type f -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 -r sha256sum) |
    sha256sum | awk '{print $1}'
}
code_hash="$(audit_hash "$PROJECT" CMakeLists.txt core/src core/include camera/src camera/include ui/backend)"
config_hash="$(audit_hash "$PROJECT" core/config camera/profiles)"
session_hash="$(audit_hash "$PROJECT" core/scripts run.sh)"
ui_hash="$(audit_hash "$PROJECT" ui/dist)"
old_code="$(cat "$STATE_DIR/code.sha" 2>/dev/null || true)"
old_config="$(cat "$STATE_DIR/config.sha" 2>/dev/null || true)"
old_session="$(cat "$STATE_DIR/session.sha" 2>/dev/null || true)"
old_ui="$(cat "$STATE_DIR/ui.sha" 2>/dev/null || true)"
code_changed=0; config_changed=0; session_changed=0; ui_changed=0
[[ "$code_hash" != "$old_code" || ! -x "$CURRENT_BINARY" ]] && code_changed=1
[[ "$config_hash" != "$old_config" ]] && config_changed=1
[[ "$session_hash" != "$old_session" ]] && session_changed=1
[[ "$ui_hash" != "$old_ui" ]] && ui_changed=1
printf '[REMOTE] code=%s config=%s session=%s ui=%s\n' \
  "$code_changed" "$config_changed" "$session_changed" "$ui_changed"

if ((code_changed)); then
  echo "[REMOTE] Isolated CUDA build; running cameras stay active during compilation..."
  jobs=2; (( $(nproc) >= 12 )) && jobs=4
  nice -n 15 ionice -c3 cmake -S "$PROJECT" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.2/bin/nvcc \
    -DCMAKE_CUDA_ARCHITECTURES=86
  nice -n 15 ionice -c3 cmake --build "$BUILD" -j"$jobs"
  test -x "$BUILD/pulsar-core"
  ldd "$BUILD/pulsar-core" | grep -q libcudart
  ! ldd "$BUILD/pulsar-core" | grep -q 'not found'
fi

[[ -x "$CURRENT_BINARY" ]] && cp -a "$CURRENT_BINARY" "$OLD_BINARY"
tar -C "$ROOT" -czf "$OLD_FILES" \
  camera/src/GpuBayerPipeline.cu camera/src/SbsRenderer.cpp camera/src/CameraDevice.cpp \
  camera/include/pulsar/camera/SdlMinimal.hpp core/include/pulsar/core/AppState.hpp \
  core/scripts/configure-displays.sh core/scripts/display-hotplug-watch.sh \
  core/scripts/restart-browser-live.sh core/scripts/start-session.sh \
  ui/backend/src/HttpServer.cpp ui/frontend/src/app ui/dist core/config \
  2>/dev/null || true

restart_core_only() {
  local old_pid
  old_pid="$(cat "$PID_FILE" 2>/dev/null || echo 0)"
  touch "$REQUEST_FILE"
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    kill -TERM "$old_pid"
  else
    sudo -n systemctl restart "$SERVICE"
  fi
}

rollback() {
  code=$?; trap - ERR
  echo "ERROR: V8 did not become ready; restoring the previous temporary runtime."
  echo "=== FAILURE LOG ==="
  tail -n 180 "$APP_LOG" 2>/dev/null || true
  echo "=== FAILURE X11 OUTPUTS ==="
  DISPLAY=:0 XAUTHORITY=/home/matin/.Xauthority xrandr --query 2>/dev/null | awk '$2=="connected" || $2=="disconnected" {print}' || true
  [[ -s "$OLD_FILES" ]] && tar -C "$ROOT" -xzf "$OLD_FILES" || true
  [[ -x "$OLD_BINARY" ]] && install -m 0755 "$OLD_BINARY" "$CURRENT_BINARY" || true
  restart_core_only >/dev/null 2>&1 || true
  exit "$code"
}
trap rollback ERR

rsync -a --delete-delay \
  --exclude='.git/' --exclude='.dev-sync/' --exclude='.pulsar-backups/' \
  --exclude='core/build/' --exclude='core/build-*/' --exclude='core/data/' \
  --exclude='node_modules/' --exclude='ui/frontend/node_modules/' --exclude='ui/frontend/dist/' \
  "$PROJECT/" "$ROOT/"
chmod +x "$ROOT/run.sh" "$ROOT/core/scripts/"*.sh
if ((code_changed)); then
  install -m 0755 "$BUILD/pulsar-core" "$ROOT/core/build/pulsar-core.new"
  mv -f "$ROOT/core/build/pulsar-core.new" "$CURRENT_BINARY"
fi

export DISPLAY=:0
export XAUTHORITY="${XAUTHORITY:-/home/matin/.Xauthority}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/pulsar-runtime-matin}"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true

# Apply the dynamic three-profile topology before restarting the C++ core.
"$ROOT/core/scripts/configure-displays.sh" >>"$APP_LOG" 2>&1 || true

if ((session_changed)); then
  watcher_pid="$(cat "$ROOT/core/data/display-hotplug.pid" 2>/dev/null || echo 0)"
  [[ "$watcher_pid" =~ ^[0-9]+$ ]] && kill "$watcher_pid" 2>/dev/null || true
  nohup env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    "$ROOT/core/scripts/display-hotplug-watch.sh" >>"$APP_LOG" 2>&1 &
  echo "[REMOTE] Hotplug watcher replaced live; Xorg remains active."
fi

start_line="$(wc -l <"$APP_LOG" 2>/dev/null || echo 0)"
if ((code_changed || config_changed)); then
  echo "[REMOTE] Core-only restart; Xorg and the UI screen stay active."
  restart_core_only
else
  echo "[REMOTE] C++ restart not required."
fi

ready=0
for _ in $(seq 1 240); do
  pid="$(cat "$PID_FILE" 2>/dev/null || echo 0)"
  if systemctl is-active --quiet "$SERVICE" && \
     [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && \
     curl -fsS --max-time 1 http://127.0.0.1:4173/health >/dev/null 2>&1; then
    if ((code_changed || config_changed)); then
      recent="$(tail -n "+$((start_line+1))" "$APP_LOG" 2>/dev/null || true)"
      if [[ "$(grep -c 'GPU pipeline ready' <<<"$recent")" -ge 2 ]] && \
         grep -q 'viewer-layout-ready=1' <<<"$recent"; then
        ready=1; break
      fi
    else
      ready=1; break
    fi
  fi
  sleep 0.5
done
((ready)) || false

if ((ui_changed)); then
  echo "[REMOTE] Restarting only the kiosk browser to load the two-glasses UI."
  "$ROOT/core/scripts/restart-browser-live.sh"
fi

printf '%s\n' "$code_hash" >"$STATE_DIR/code.sha"
printf '%s\n' "$config_hash" >"$STATE_DIR/config.sha"
printf '%s\n' "$session_hash" >"$STATE_DIR/session.sha"
printf '%s\n' "$ui_hash" >"$STATE_DIR/ui.sha"
trap - ERR

# Reapply after core readiness; the renderer reloads viewer-layout.env live.
"$ROOT/core/scripts/configure-displays.sh" >>"$APP_LOG" 2>&1 || true
sleep 2

echo
echo "=== LIVE THREE-PROFILE ROUTING ==="
cat "$ROOT/core/data/displays.env" 2>/dev/null || true
echo
echo "=== VIEWER LAYOUT ==="
cat "$ROOT/core/data/viewer-layout.env" 2>/dev/null || true
echo
echo "=== RECENT CAMERA/RENDER ==="
tail -n 180 "$APP_LOG" | grep -aE \
  'GPU pipeline ready|viewer-layout-ready|live-layout-update|latency-stats|software-start-sync=' | tail -n 36 || true

echo
echo "=== AUTOMATIC 20-SECOND DIAGNOSIS ==="
"$ROOT/core/scripts/realtime-20s-diagnose.sh" 20

echo
echo "============================================================"
echo "FINAL_STATUS=V8_TWO_GLASSES_INDEPENDENT_ACTIVE"
echo "LATEST_PROJECT_UPLOADED=YES"
echo "VIEWER_PROFILES=3"
echo "MONITOR_DEFAULT_MODE=2D"
echo "GLASS1_DEFAULT_MODE=3D"
echo "GLASS2_DEFAULT_MODE=3D"
echo "GLASS_LOGICAL_SBS=3840x1080"
echo "INDEPENDENT_SCANOUT=YES"
echo "SHARED_CAMERA_TEXTURE_UPLOAD=YES"
echo "LIVE_HOTPLUG=YES"
echo "XORG_RESTARTED=NO"
echo "PERSISTENT_BACKUP=NO"
echo "GIT_USED=NO"
echo "============================================================"
REMOTE

chmod 700 /tmp/pulsar-atomic-v8-remote.sh

echo "[SSH] Connecting to $REMOTE_USER@$SERVER ..."
echo "رمز SSH کاربر matin را یک‌بار وارد کن."
ssh -M -S "$SOCKET" -o ControlPersist=300 -o StrictHostKeyChecking=accept-new \
  -fnN "$REMOTE_USER@$SERVER"
scp -o ControlPath="$SOCKET" "$ARCHIVE" "$REMOTE_USER@$SERVER:$REMOTE_ARCHIVE"
scp -o ControlPath="$SOCKET" /tmp/pulsar-atomic-v8-remote.sh "$REMOTE_USER@$SERVER:$REMOTE_APPLY"
set +e
ssh -o ControlPath="$SOCKET" "$REMOTE_USER@$SERVER" \
  "PULSAR_ROOT='$REMOTE_ROOT' PULSAR_ARCHIVE='$REMOTE_ARCHIVE' PULSAR_SERVICE='$REMOTE_SERVICE' PULSAR_TS='$TS' bash '$REMOTE_APPLY'" \
  2>&1 | tee "$LOCAL_LOG"
status=${PIPESTATUS[0]}
set -e
echo "Log: $LOCAL_LOG"
exit "$status"
