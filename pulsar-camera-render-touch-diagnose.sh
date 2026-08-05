#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="${PULSAR_PROJECT:-$HOME/Pictures/Pulsar-pro}"
REMOTE_USER="${PULSAR_REMOTE_USER:-matin}"
REMOTE_HOST="${PULSAR_REMOTE_HOST:-192.168.1.123}"
REMOTE_ROOT="${PULSAR_REMOTE_ROOT:-/home/matin/Pulsar-Cpp-Core}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOCAL_ARCHIVE="$HOME/Pictures/pulsar-camera-render-touch-$STAMP.tar.gz"

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

[[ -d "$PROJECT" ]] || fail "Project not found: $PROJECT"
cd "$PROJECT"

echo "========== ENABLE LOCAL RUN LOGGING =========="

python3 - <<'PY'
from pathlib import Path

run = Path("run.sh")
text = run.read_text()

marker = "PULSAR_PERSISTENT_RUN_LOG_V1"
if marker not in text:
    old = "#!/usr/bin/env bash\nset -euo pipefail\n"
    new = '''#!/usr/bin/env bash
set -euo pipefail

# PULSAR_PERSISTENT_RUN_LOG_V1
# Keep every run transcript locally. Runtime logs are intentionally excluded
# from Git; only project source/configuration changes are committed and pushed.
if [[ "${PULSAR_RUN_LOGGING_ACTIVE:-0}" != "1" ]]; then
  early_root="$(cd "$(dirname "$0")" && pwd)"
  run_log_dir="$early_root/run-logs"
  mkdir -p "$run_log_dir"
  run_log_file="$run_log_dir/run-$(date +%Y%m%d-%H%M%S).log"
  export PULSAR_RUN_LOGGING_ACTIVE=1
  export PULSAR_RUN_LOG_FILE="$run_log_file"
  exec > >(tee -a "$run_log_file") 2>&1
  printf 'Pulsar run log: %s\\n' "$run_log_file"
fi
'''
    if old not in text:
        raise SystemExit("run.sh header was not found; no edit was made")
    run.write_text(text.replace(old, new, 1))
    print("run.sh: persistent local logging enabled")
else:
    print("run.sh: logging patch already exists")

ignore = Path(".gitignore")
ignore_text = ignore.read_text() if ignore.exists() else ""
entries = [
    "run-logs/",
    "pulsar-*-diagnostics-*.tar.gz",
    "pulsar-camera-render-touch-*.tar.gz",
]
changed = False
lines = ignore_text.splitlines()
for entry in entries:
    if entry not in lines:
        if ignore_text and not ignore_text.endswith("\n"):
            ignore_text += "\n"
        ignore_text += entry + "\n"
        changed = True
if changed:
    ignore.write_text(ignore_text)
    print(".gitignore: runtime diagnostics excluded from Git")
else:
    print(".gitignore: diagnostic exclusions already present")
PY

bash -n run.sh
git diff --check

echo
echo "========== BUILD REMOTE DIAGNOSTIC COLLECTOR =========="

cat > /tmp/pulsar-camera-render-touch-diagnose.sh <<'REMOTE'
#!/usr/bin/env bash
set -u
set -o pipefail

export LC_ALL=C
export LANG=C
export DISPLAY="${DISPLAY:-:0}"
[[ -f /home/matin/.Xauthority ]] &&
  export XAUTHORITY=/home/matin/.Xauthority

ROOT=/home/matin/Pulsar-Cpp-Core
OUT=/tmp/pulsar-camera-render-touch-diagnostics
ARCHIVE=/tmp/pulsar-camera-render-touch-diagnostics.tar.gz

rm -rf "$OUT" "$ARCHIVE"
mkdir -p "$OUT/files" "$OUT/screenshots" "$OUT/frames"

capture() {
  local name="$1"
  shift
  {
    echo "COMMAND: $*"
    echo "DATE: $(date --iso-8601=seconds)"
    echo
    timeout 40 bash -lc "$*"
  } >"$OUT/${name}.txt" 2>&1 || true
}

copy_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local safe="${file#/}"
  safe="${safe//\//__}"
  cp -a "$file" "$OUT/files/$safe"
}

capture 00-summary '
echo "HOST=$(hostname)"
echo "BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)"
echo "UPTIME=$(cut -d. -f1 /proc/uptime)"
echo "DATE=$(date --iso-8601=seconds)"
echo
systemctl is-active pulsar-kiosk.service
curl -fsS --max-time 3 http://127.0.0.1:4173/health
echo
'

capture 01-service '
systemctl --no-pager --full status pulsar-kiosk.service
echo
systemctl show pulsar-kiosk.service \
  -p ActiveState -p SubState -p MainPID -p ExecMainStartTimestamp \
  -p NRestarts -p Restart -p TimeoutStartUSec -p DropInPaths
echo
systemctl cat pulsar-kiosk.service
'

capture 02-api '
echo "===== HEALTH ====="
curl -fsS --max-time 3 http://127.0.0.1:4173/health
echo
echo "===== CAMERAS ====="
curl -fsS --max-time 3 http://127.0.0.1:4173/api/cameras
echo
echo "===== STATE ====="
curl -fsS --max-time 3 http://127.0.0.1:4173/api/state
echo
'

for index in 0 1; do
  curl -fsS --max-time 5 \
    "http://127.0.0.1:4173/camera/$index/frame.jpg" \
    -o "$OUT/frames/camera-${index}-a.jpg" || true
done
sleep 3
for index in 0 1; do
  curl -fsS --max-time 5 \
    "http://127.0.0.1:4173/camera/$index/frame.jpg" \
    -o "$OUT/frames/camera-${index}-b.jpg" || true
done

capture 03-frame-checks '
file /tmp/pulsar-camera-render-touch-diagnostics/frames/* 2>/dev/null
echo
sha256sum /tmp/pulsar-camera-render-touch-diagnostics/frames/* 2>/dev/null
echo
if command -v identify >/dev/null 2>&1; then
  identify /tmp/pulsar-camera-render-touch-diagnostics/frames/* 2>/dev/null
fi
'

capture 04-processes '
ps -eo pid,ppid,user,stat,ni,pri,psr,%cpu,%mem,etimes,comm,args \
  --sort=-%cpu
echo
echo "===== PROCESS TREE ====="
pstree -ap
'

capture 05-core-process '
pid="$(pgrep -xo pulsar-core || true)"
echo "PID=$pid"
[ -n "$pid" ] || exit 0
echo
echo "===== CMDLINE ====="
tr "\0" " " <"/proc/$pid/cmdline"
echo
echo "===== ENVIRONMENT ====="
tr "\0" "\n" <"/proc/$pid/environ" | sort
echo
echo "===== STATUS ====="
cat "/proc/$pid/status"
echo
echo "===== LIBRARIES ====="
grep -Ei "SDL|nvidia|libGL|libEGL|cuda|gxi" "/proc/$pid/maps" | sort -u
echo
echo "===== FDS ====="
ls -la "/proc/$pid/fd" | head -n 300
'

capture 06-journal '
journalctl -b 0 -u pulsar-kiosk.service \
  --no-pager -o short-monotonic
'

capture 07-pulsar-renderer-log '
grep -Eina \
"SBS Renderer|SDL|viewer|layout|texture|PBO|OpenGL|render|camera|GXOpenDevice|latency-stats|error|failed|offline" \
"$ROOT/core/data/pulsar.log" | tail -n 2500
'

capture 08-pulsar-log-tail '
tail -n 4000 "$ROOT/core/data/pulsar.log"
'

capture 09-layout-files '
for file in \
  "$ROOT/core/data/viewer-layout.env" \
  "$ROOT/core/data/displays.env" \
  "$ROOT/core/data/display-routing.env"; do
  echo
  echo "========== $file =========="
  if [ -f "$file" ]; then
    echo "--- normal ---"
    cat "$file"
    echo "--- escaped lines ---"
    sed -n l "$file"
    echo "--- bytes ---"
    xxd -g1 "$file"
    echo "--- bash syntax/source test ---"
    bash -n "$file"
    (
      set +e
      set -a
      source "$file"
      rc=$?
      set +a
      echo "SOURCE_RC=$rc"
      env | grep -E "^PULSAR_(VIEWER|ROLE|SETTINGS|MAIN|AUX|RTX)" | sort
    )
  else
    echo "MISSING"
  fi
done
'

capture 10-xrandr '
echo "===== QUERY ====="
xrandr --query
echo
echo "===== VERBOSE ====="
xrandr --verbose
echo
echo "===== MONITORS ====="
xrandr --listmonitors
echo
echo "===== PROVIDERS ====="
xrandr --listproviders
echo
echo "===== SCREEN ====="
xdpyinfo | sed -n "/screen #0:/,/number of visuals:/p"
'

capture 11-windows '
echo "===== WMCTRL ====="
wmctrl -lGx 2>&1
echo
echo "===== ROOT TREE ====="
xwininfo -root -tree
echo
echo "===== CLIENT LIST ====="
xprop -root _NET_CLIENT_LIST _NET_CLIENT_LIST_STACKING \
  _NET_ACTIVE_WINDOW _NET_CURRENT_DESKTOP 2>&1

ids="$(
  xwininfo -root -tree 2>/dev/null |
  awk "/Pulsar Multi-Output Viewer/ {print \$1}"
)"
for id in $ids; do
  echo
  echo "===== VIEWER $id ====="
  xwininfo -id "$id"
  xprop -id "$id"
  if command -v xdotool >/dev/null 2>&1; then
    xdotool getwindowgeometry --shell "$id"
  fi
done
'

capture 12-gl-nvidia '
echo "===== GLX ====="
glxinfo -B 2>&1
echo
echo "===== NVIDIA-SMI ====="
nvidia-smi
echo
echo "===== NVIDIA PROCESSES ====="
nvidia-smi pmon -c 1
echo
echo "===== GPU APPS ====="
nvidia-smi \
  --query-compute-apps=pid,process_name,used_memory \
  --format=csv,noheader
echo
echo "===== MODULES ====="
lsmod | grep -E "nvidia|nouveau|i915"
'

capture 13-camera-usb-sysfs '
for dev in /sys/bus/usb/devices/*; do
  [ -r "$dev/idVendor" ] || continue
  [ -r "$dev/idProduct" ] || continue
  vendor="$(cat "$dev/idVendor")"
  product="$(cat "$dev/idProduct")"
  [ "$vendor:$product" = "2ba2:4d55" ] || continue

  echo "========== $(basename "$dev") =========="
  for field in \
    idVendor idProduct manufacturer product serial speed version \
    busnum devnum devpath authorized power/control \
    power/runtime_status power/autosuspend_delay_ms; do
    if [ -r "$dev/$field" ]; then
      printf "%-30s = " "$field"
      cat "$dev/$field"
    fi
  done

  echo "interfaces:"
  for interface in "$dev":*; do
    [ -d "$interface" ] || continue
    echo "  $(basename "$interface") driver=$(basename "$(readlink -f "$interface/driver" 2>/dev/null)")"
  done
done
'

capture 14-camera-sdk-state '
grep -Eina \
"Left Camera|Right Camera|GXOpenDevice|GXStreamOn|profile|serial|offline|online|latency-stats|fps|USB|stream" \
"$ROOT/core/data/pulsar.log" | tail -n 3000
'

capture 15-touch '
echo "===== XINPUT ====="
xinput --list
echo
for id in $(xinput --list --id-only 2>/dev/null | sort -nu); do
  echo "===== XINPUT ID $id ====="
  xinput list-props "$id" 2>&1
done
echo
echo "===== INPUT DEVICES ====="
cat /proc/bus/input/devices
echo
echo "===== TOUCH USB SYSFS ====="
for dev in /sys/bus/usb/devices/*; do
  [ -r "$dev/idVendor" ] || continue
  [ -r "$dev/idProduct" ] || continue
  id="$(cat "$dev/idVendor"):$(cat "$dev/idProduct")"
  case "$id" in
    4348:55e0|1a86:e5e3)
      echo "DEVICE=$(basename "$dev") ID=$id"
      for field in product manufacturer serial speed bDeviceClass; do
        [ -r "$dev/$field" ] && {
          printf "%s=" "$field"
          cat "$dev/$field"
        }
      done
      ;;
  esac
done
echo
echo "===== TOUCH LOG ====="
tail -n 1000 "$ROOT/core/data/touch.log" 2>/dev/null
'

capture 16-config '
for file in \
  "$ROOT/core/config/pulsar.env" \
  "$ROOT/core/config/pulsar.local.env"; do
  echo
  echo "========== $file =========="
  sed -E \
    "/^[[:space:]]*#/b;
     s/^([^=]*(PASSWORD|PASS|TOKEN|SECRET|COOKIE|PRIVATE_KEY|API_KEY)[^=]*)=.*/\1=<REDACTED>/I" \
    "$file"
done
'

capture 17-git-deploy-state '
cd "$ROOT"
git status --short
echo
git log -n 15 --oneline --decorate
echo
git diff --stat
echo
git remote -v
echo
echo "===== RUN LOGGING ====="
grep -n "PULSAR_PERSISTENT_RUN_LOG" run.sh || true
echo
echo "===== DEPLOY VERIFY ====="
grep -RInE \
"verify-displays|configure-touch.sh.*--watch|viewer-layout|restart-core|systemctl restart" \
run.sh core/scripts/dev-sync.sh core/scripts/atomic-remote-deploy.sh \
core/scripts/start-session.sh core/scripts/verify-displays.sh 2>/dev/null
'

capture 18-source-inspection '
echo "===== START SESSION ====="
sed -n "1,460p" "$ROOT/core/scripts/start-session.sh"
echo
echo "===== CONFIGURE DISPLAYS ====="
sed -n "1,460p" "$ROOT/core/scripts/configure-displays.sh"
echo
echo "===== VERIFY ====="
sed -n "1,300p" "$ROOT/core/scripts/verify-displays.sh"
echo
echo "===== RENDERER START ====="
sed -n "640,940p" "$ROOT/camera/src/SbsRenderer.cpp"
'

capture 19-kernel-current '
journalctl -k -b 0 --no-pager |
grep -Ei \
"usb|xhci|nvidia|drm|i915|2ba2|4d55|4348|55e0|1a86|e5e3|hid|touch|error|fail|reset" |
tail -n 2500
'

screen_geometry="$(
  xrandr --query 2>/dev/null |
  awk '/^Screen 0:/ {
    for (i=1; i<=NF; i++) {
      if ($i=="current") {
        gsub(/,/,"",$(i+1))
        gsub(/,/,"",$(i+3))
        print $(i+1)"x"$(i+3)
        exit
      }
    }
  }'
)"

if command -v import >/dev/null 2>&1; then
  timeout 15 import -window root "$OUT/screenshots/root.png" 2>"$OUT/screenshots/root-error.txt" || true
elif command -v ffmpeg >/dev/null 2>&1 && [[ -n "$screen_geometry" ]]; then
  timeout 15 ffmpeg -y -loglevel error \
    -f x11grab -video_size "$screen_geometry" -i :0.0 \
    -frames:v 1 "$OUT/screenshots/root.png" \
    2>"$OUT/screenshots/root-error.txt" || true
elif command -v xwd >/dev/null 2>&1; then
  timeout 15 xwd -silent -root -out "$OUT/screenshots/root.xwd" \
    2>"$OUT/screenshots/root-error.txt" || true
fi

viewer_id="$(
  xwininfo -root -tree 2>/dev/null |
  awk '/Pulsar Multi-Output Viewer/ {print $1; exit}'
)"
if [[ -n "$viewer_id" ]]; then
  if command -v import >/dev/null 2>&1; then
    timeout 15 import -window "$viewer_id" \
      "$OUT/screenshots/viewer.png" \
      2>"$OUT/screenshots/viewer-error.txt" || true
  elif command -v xwd >/dev/null 2>&1; then
    timeout 15 xwd -silent -id "$viewer_id" \
      -out "$OUT/screenshots/viewer.xwd" \
      2>"$OUT/screenshots/viewer-error.txt" || true
  fi
fi

for file in \
  "$ROOT/core/data/viewer-layout.env" \
  "$ROOT/core/data/displays.env" \
  "$ROOT/core/data/display-routing.env" \
  "$ROOT/core/data/pulsar.log" \
  "$ROOT/core/data/touch.log" \
  "$ROOT/core/data/browser.log" \
  "$ROOT/core/scripts/start-session.sh" \
  "$ROOT/core/scripts/configure-displays.sh" \
  "$ROOT/core/scripts/configure-touch.sh" \
  "$ROOT/core/scripts/verify-displays.sh" \
  "$ROOT/core/scripts/dev-sync.sh" \
  "$ROOT/core/scripts/atomic-remote-deploy.sh" \
  "$ROOT/run.sh" \
  "$ROOT/camera/src/SbsRenderer.cpp"; do
  copy_file "$file"
done

{
  echo "Diagnostic generated: $(date --iso-8601=seconds)"
  echo
  echo "===== HEALTH ====="
  curl -fsS --max-time 3 http://127.0.0.1:4173/health || true
  echo
  echo
  echo "===== CAMERAS ====="
  curl -fsS --max-time 3 http://127.0.0.1:4173/api/cameras || true
  echo
  echo
  echo "===== ACTIVE OUTPUTS ====="
  xrandr --query 2>/dev/null |
    grep -E '^(HDMI-2|DP-1-1|HDMI-1-0) connected' || true
  echo
  echo "===== VIEWER WINDOW ====="
  xwininfo -root -tree 2>/dev/null |
    grep 'Pulsar Multi-Output Viewer' || true
  echo
  echo "===== LAYOUT ====="
  cat "$ROOT/core/data/viewer-layout.env" 2>/dev/null || true
  echo
  echo "===== TOUCH ====="
  touch_id=""
  for dev in /sys/bus/usb/devices/*; do
    [ -r "$dev/idVendor" ] || continue
    [ -r "$dev/idProduct" ] || continue
    id="$(cat "$dev/idVendor"):$(cat "$dev/idProduct")"
    case "$id" in
      4348:55e0|1a86:e5e3)
        echo "$id at $(basename "$dev")"
        touch_id="$id"
        ;;
    esac
  done
  [ -n "$touch_id" ] || echo "No known touch controller found"
} >"$OUT/README-FIRST.txt" 2>&1

tar -C /tmp -czf "$ARCHIVE" "$(basename "$OUT")"
chmod 0644 "$ARCHIVE"

echo "DIAGNOSTIC_READY=$ARCHIVE"
ls -lh "$ARCHIVE"
REMOTE

chmod +x /tmp/pulsar-camera-render-touch-diagnose.sh
bash -n /tmp/pulsar-camera-render-touch-diagnose.sh

echo
echo "========== COLLECT FROM SERVER =========="

scp /tmp/pulsar-camera-render-touch-diagnose.sh \
  "${REMOTE_USER}@${REMOTE_HOST}:/tmp/pulsar-camera-render-touch-diagnose.sh"

ssh "${REMOTE_USER}@${REMOTE_HOST}" \
  'bash /tmp/pulsar-camera-render-touch-diagnose.sh'

scp "${REMOTE_USER}@${REMOTE_HOST}:/tmp/pulsar-camera-render-touch-diagnostics.tar.gz" \
  "$LOCAL_ARCHIVE"

echo
echo "========== COMPLETE =========="
echo "Diagnostic archive:"
echo "$LOCAL_ARCHIVE"
echo
echo "run.sh logs will now be stored under:"
echo "$PROJECT/run-logs/"
echo
echo "The run-logs directory is excluded from Git."
