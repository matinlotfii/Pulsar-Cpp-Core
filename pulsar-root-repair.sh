#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="${PULSAR_PROJECT:-$HOME/Pictures/Pulsar-pro}"
REMOTE_USER="${PULSAR_REMOTE_USER:-matin}"
REMOTE_HOST="${PULSAR_REMOTE_HOST:-192.168.1.123}"
REMOTE_ROOT="${PULSAR_REMOTE_ROOT:-/home/matin/Pulsar-Cpp-Core}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOCAL_REPORT="$HOME/Pictures/pulsar-root-repair-report-$STAMP.txt"

fail() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

[[ -d "$PROJECT/core/scripts" ]] ||
    fail "Project was not found at $PROJECT"

cd "$PROJECT"

echo "========== LOCAL BACKUP =========="
BACKUP_DIR=".pulsar-backups/root-repair-$STAMP"
mkdir -p "$BACKUP_DIR/core/scripts" "$BACKUP_DIR/core/config"

for file in \
    core/scripts/configure-touch.sh \
    core/scripts/touch-hotplug-event.sh \
    core/scripts/install-service.sh \
    core/scripts/pulsar-boot-preflight.sh \
    core/config/99-pulsar-touch-hotplug.rules; do
    [[ -f "$file" ]] || continue
    cp -a "$file" "$BACKUP_DIR/$file"
done

echo "Backup: $PROJECT/$BACKUP_DIR"

echo
echo "========== PATCH PROJECT PERMANENTLY =========="

python3 - <<'PY'
from pathlib import Path
import re

def require(path: str) -> Path:
    p = Path(path)
    if not p.exists():
        raise SystemExit(f"Missing required file: {path}")
    return p

def replace_once(path: str, old: str, new: str, marker: str) -> None:
    p = require(path)
    text = p.read_text()
    if marker in text:
        print(f"{path}: already patched")
        return
    if old not in text:
        raise SystemExit(
            f"{path}: expected block not found; no unsafe partial edit was made"
        )
    p.write_text(text.replace(old, new, 1))
    print(f"{path}: patched")

# lsusb blocks for tens of seconds while the broken USB3 link is retraining.
# Reading idVendor/idProduct from sysfs is immediate and does not probe buses.
replace_once(
    "core/scripts/configure-touch.sh",
    '''touch_controller_in_bootloader() {
  command -v lsusb >/dev/null 2>&1 || return 1
  lsusb | grep -Eiq "[[:space:]]${bootloader_ids_regex}[[:space:]]"
}
''',
    '''touch_controller_in_bootloader() {
  # PULSAR_FAST_SYSFS_TOUCH_DETECT_V3
  local dev vendor product
  for dev in /sys/bus/usb/devices/*; do
    [[ -r "$dev/idVendor" && -r "$dev/idProduct" ]] || continue
    vendor="$(<"$dev/idVendor")"
    product="$(<"$dev/idProduct")"
    if [[ "${vendor,,}:${product,,}" == "4348:55e0" ]]; then
      return 0
    fi
  done
  return 1
}
''',
    "PULSAR_FAST_SYSFS_TOUCH_DETECT_V3",
)

# The udev-triggered service must be a fast one-shot. Continuous monitoring is
# already handled by udev itself and must never keep boot unfinished.
touch_event = require("core/scripts/touch-hotplug-event.sh")
touch_event.write_text(r'''#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
load_config

# PULSAR_NONBLOCKING_TOUCH_HOTPLUG_V3
lock_file="/run/pulsar-touch-hotplug.lock"
mkdir -p "$(dirname "$lock_file")"
exec 9>"$lock_file"
flock -n 9 || exit 0

bootloader_present() {
  local dev
  for dev in /sys/bus/usb/devices/*; do
    [[ -r "$dev/idVendor" && -r "$dev/idProduct" ]] || continue
    if [[ "$(<"$dev/idVendor")" == "4348" &&
          "$(<"$dev/idProduct")" == "55e0" ]]; then
      return 0
    fi
  done
  return 1
}

# Bootloader mode cannot produce XInput events. Exit immediately rather than
# repeatedly probing every USB bus and keeping systemd boot active.
if bootloader_present; then
  warn "WCH touch controller is in 4348:55e0 bootloader mode; hotplug mapper skipped."
  exit 0
fi

run_user="${PULSAR_RUN_USER:-$(stat -c '%U' "$PULSAR_ROOT")}"
if [[ -z "$run_user" || "$run_user" == "root" ]]; then
  run_user="${SUDO_USER:-matin}"
fi

user_home="$(getent passwd "$run_user" | cut -d: -f6)"
[[ -n "$user_home" ]] || user_home="/home/$run_user"
xauthority="$user_home/.Xauthority"
xdg_runtime_dir="/tmp/pulsar-runtime-$run_user"

mkdir -p "$xdg_runtime_dir"
chown "$run_user":"$(id -gn "$run_user")" "$xdg_runtime_dir"
chmod 700 "$xdg_runtime_dir"

env_args=(
  DISPLAY="${DISPLAY:-:0}"
  XDG_RUNTIME_DIR="$xdg_runtime_dir"
  HOME="$user_home"
  USER="$run_user"
  LOGNAME="$run_user"
)
[[ -f "$xauthority" ]] && env_args+=(XAUTHORITY="$xauthority")

run_as_user() {
  runuser -u "$run_user" -- env "${env_args[@]}" "$@"
}

attempts="${PULSAR_TOUCH_X11_READY_ATTEMPTS:-10}"
interval="${PULSAR_TOUCH_X11_READY_INTERVAL_SEC:-0.5}"

for _ in $(seq 1 "$attempts"); do
  if run_as_user xset q >/dev/null 2>&1; then
    run_as_user \
      "$PULSAR_ROOT/core/scripts/configure-touch.sh" || true
    exit 0
  fi
  sleep "$interval"
done

warn "Touch hotplug mapper could not reach X11 quickly; startup will continue."
exit 0
''')
print("core/scripts/touch-hotplug-event.sh: rewritten as bounded one-shot")

# Do not start a systemd job for the known unusable bootloader device.
# A healthy WCH HID controller and every real touchscreen input still trigger
# automatic remapping after boot and after USB reconnect.
rules = require("core/config/99-pulsar-touch-hotplug.rules")
rules.write_text(
    'ACTION=="add|change", SUBSYSTEM=="usb", '
    'ATTR{idVendor}=="1a86", ATTR{idProduct}=="e5e3", '
    'TAG+="systemd", ENV{SYSTEMD_WANTS}+="pulsar-touch-hotplug.service"\n'
    'ACTION=="add|change", SUBSYSTEM=="input", '
    'ENV{ID_INPUT_TOUCHSCREEN}=="1", '
    'TAG+="systemd", ENV{SYSTEMD_WANTS}+="pulsar-touch-hotplug.service"\n'
)
print("core/config/99-pulsar-touch-hotplug.rules: bootloader trigger removed")

install = require("core/scripts/install-service.sh")
text = install.read_text()

touch_unit_pattern = re.compile(
    r'cat >"\$touch_unit" <<UNIT\n'
    r'\[Unit\]\n'
    r'Description=Pulsar touchscreen hotplug remapper\n'
    r'After=pulsar-kiosk\.service\n\n'
    r'\[Service\]\n'
    r'Type=oneshot\n'
    r'Environment=PULSAR_ROOT=\$PULSAR_ROOT\n'
    r'ExecStart=\$PULSAR_ROOT/core/scripts/touch-hotplug-event\.sh\n'
    r'UNIT',
    re.M,
)

touch_unit_new = '''cat >"$touch_unit" <<UNIT
[Unit]
Description=Pulsar touchscreen hotplug remapper
After=pulsar-kiosk.service

[Service]
Type=oneshot
Environment=PULSAR_ROOT=$PULSAR_ROOT
ExecStart=$PULSAR_ROOT/core/scripts/touch-hotplug-event.sh
TimeoutStartSec=8
Nice=10
IOSchedulingClass=idle
UNIT'''

if "PULSAR_BOUNDED_TOUCH_UNIT_V3" not in text:
    match = touch_unit_pattern.search(text)
    if not match:
        raise SystemExit(
            "install-service.sh: touch unit block not found; no unsafe edit was made"
        )
    text = (
        text[:match.start()]
        + "# PULSAR_BOUNDED_TOUCH_UNIT_V3\n"
        + touch_unit_new
        + text[match.end():]
    )

old_refresh = '''udevadm control --reload-rules || true
udevadm trigger --subsystem-match=usb || true
udevadm trigger --subsystem-match=input || true
systemctl start pulsar-touch-hotplug.service || true
'''

new_refresh = '''# PULSAR_SAFE_TOUCH_REFRESH_V3
udevadm control --reload-rules || true
udevadm trigger --subsystem-match=input --action=add || true
timeout 8 systemctl start pulsar-touch-hotplug.service || true
'''

if "PULSAR_SAFE_TOUCH_REFRESH_V3" not in text:
    if old_refresh not in text:
        raise SystemExit(
            "install-service.sh: touch refresh block not found; no unsafe edit was made"
        )
    text = text.replace(old_refresh, new_refresh, 1)

install.write_text(text)
print("core/scripts/install-service.sh: bounded touch unit and safe refresh applied")

preflight = require("core/scripts/pulsar-boot-preflight.sh")
text = preflight.read_text()

text = text.replace(
    'stable_samples_needed="${PULSAR_BOOT_PREFLIGHT_STABLE_SAMPLES:-2}"',
    'stable_samples_needed="${PULSAR_BOOT_PREFLIGHT_STABLE_SAMPLES:-1}"',
)
text = text.replace(
    'sample_interval="${PULSAR_BOOT_PREFLIGHT_SAMPLE_INTERVAL_SEC:-1}"',
    'sample_interval="${PULSAR_BOOT_PREFLIGHT_SAMPLE_INTERVAL_SEC:-0.25}"',
)
text = text.replace(
    'timeout_sec="${PULSAR_BOOT_PREFLIGHT_TIMEOUT_SEC:-12}"',
    'timeout_sec="${PULSAR_BOOT_PREFLIGHT_TIMEOUT_SEC:-4}"',
)
text = text.replace(
    'final_delay="${PULSAR_BOOT_PREFLIGHT_FINAL_DELAY_SEC:-0.5}"',
    'final_delay="${PULSAR_BOOT_PREFLIGHT_FINAL_DELAY_SEC:-0}"',
)

if "PULSAR_NO_GLOBAL_UDEV_SETTLE_V3" not in text:
    text = text.replace(
        'udev_timeout="${PULSAR_BOOT_PREFLIGHT_UDEV_SETTLE_TIMEOUT_SEC:-3}"\n',
        '',
    )
    old = '''systemctl start nvidia-persistenced.service 2>/dev/null || true
udevadm settle --timeout="$udev_timeout" 2>/dev/null || true
'''
    new = '''systemctl start nvidia-persistenced.service 2>/dev/null || true
# PULSAR_NO_GLOBAL_UDEV_SETTLE_V3
# Global udev settle waits for every faulty/hotplug USB port. Pulsar checks
# only its own NVIDIA and camera sysfs nodes below.
'''
    if old not in text:
        raise SystemExit(
            "pulsar-boot-preflight.sh: udev settle block not found"
        )
    text = text.replace(old, new, 1)

preflight.write_text(text)
print("core/scripts/pulsar-boot-preflight.sh: global udev settle removed")
PY

chmod +x \
    core/scripts/configure-touch.sh \
    core/scripts/touch-hotplug-event.sh \
    core/scripts/install-service.sh \
    core/scripts/pulsar-boot-preflight.sh

bash -n \
    core/scripts/configure-touch.sh \
    core/scripts/touch-hotplug-event.sh \
    core/scripts/install-service.sh \
    core/scripts/pulsar-boot-preflight.sh

git diff --check

echo
echo "========== DEPLOY PATCHED PROJECT =========="
RUN_GIT_COMMIT_MESSAGE="Fix boot blockers and nonblocking USB touch hotplug" ./run.sh

echo
echo "========== CREATE SERVER ROOT REPAIR =========="

cat > /tmp/pulsar-root-repair-remote.sh <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=/home/matin/Pulsar-Cpp-Core
CFG="$ROOT/core/config/pulsar.local.env"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/home/matin/pulsar-root-repair-backup-$STAMP"

mkdir -p "$BACKUP/systemd" "$BACKUP/config"
cp -a /etc/systemd/system/pulsar-kiosk.service* "$BACKUP/systemd/" 2>/dev/null || true
cp -a /etc/systemd/system/pulsar-touch-hotplug.service* "$BACKUP/systemd/" 2>/dev/null || true
cp -a /etc/udev/rules.d/99-pulsar-touch-hotplug.rules "$BACKUP/systemd/" 2>/dev/null || true
cp -a "$CFG" "$BACKUP/config/" 2>/dev/null || true
chown -R matin:matin "$BACKUP"

touch "$CFG"

upsert() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$CFG"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$CFG"
    else
        printf '%s=%s\n' "$key" "$value" >>"$CFG"
    fi
}

echo "========== STOP STUCK TOUCH JOBS =========="
systemctl stop pulsar-touch-hotplug.service 2>/dev/null || true
pkill -f 'configure-touch.sh --watch' 2>/dev/null || true
pkill -f '^lsusb$' 2>/dev/null || true

echo "========== REMOVE STALE BOOT BLOCKERS =========="
rm -f \
    /etc/systemd/system/pulsar-kiosk.service.d/40-boot-preflight.conf \
    /etc/systemd/system/pulsar-kiosk.service.d/override.conf

# The application retries cameras itself. Do not hold the graphical boot target
# for a physically missing or late camera.
upsert PULSAR_BOOT_PREFLIGHT_ENABLED 1
upsert PULSAR_BOOT_PREFLIGHT_REQUIRED_CAMERAS 0
upsert PULSAR_BOOT_PREFLIGHT_STABLE_SAMPLES 1
upsert PULSAR_BOOT_PREFLIGHT_SAMPLE_INTERVAL_SEC 0.25
upsert PULSAR_BOOT_PREFLIGHT_TIMEOUT_SEC 4
upsert PULSAR_BOOT_PREFLIGHT_FINAL_DELAY_SEC 0

# Udev is the durable hotplug mechanism. No permanent polling loop is needed.
upsert PULSAR_TOUCH_HOTPLUG_WATCH 0
upsert PULSAR_TOUCH_X11_READY_ATTEMPTS 10
upsert PULSAR_TOUCH_X11_READY_INTERVAL_SEC 0.5
upsert PULSAR_REQUIRE_TOUCH 0

# Keep the known stable display and camera performance configuration.
upsert PULSAR_CAMERA_PROFILE_ENABLED 0
upsert PULSAR_CAMERA_PROFILE_REQUIRED 0
upsert PULSAR_CAMERA_PROFILE_VERIFY 0
upsert PULSAR_CAMERA_FPS 32
upsert PULSAR_PREVIEW_FPS 30
upsert PULSAR_CAMERA_SENSOR_SCALE 4
upsert PULSAR_GPU_PIPELINE both
upsert PULSAR_GL_PBO_UPLOAD 1
upsert PULSAR_SBS_PRESENT_VSYNC 1
upsert __GL_SYNC_TO_VBLANK 1
upsert vblank_mode 1

echo "========== REFRESH PULSAR UNITS =========="
bash "$ROOT/core/scripts/install-service.sh" --refresh

# Guard against future accidental edits that reintroduce an infinite start.
mkdir -p /etc/systemd/system/pulsar-touch-hotplug.service.d
cat >/etc/systemd/system/pulsar-touch-hotplug.service.d/10-bounded.conf <<'EOF'
[Service]
TimeoutStartSec=8
EOF

echo "========== REMOVE UNUSED SERVER STARTUP NOISE =========="

# systemd-networkd is masked and NetworkManager is active. Its dispatcher only
# emits errors about unmanaged interfaces on this machine.
systemctl disable --now networkd-dispatcher.service 2>/dev/null || true

# No cellular modem exists in the collected hardware inventory.
if ! find /sys/class/net -maxdepth 1 -type l \
    -exec sh -c 'udevadm info -q property -p "$1" 2>/dev/null' _ {} \; |
    grep -Eq '^ID_MM_CANDIDATE=1$'; then
    systemctl disable --now ModemManager.service 2>/dev/null || true
fi

# This bare-metal machine reports DataSourceNone. Disable cloud-init only in
# that exact case; SSH and NetworkManager remain enabled.
cloud_source="$(cloud-id 2>/dev/null || true)"
if [[ "$cloud_source" == "none" ]] ||
   journalctl -b 0 -u cloud-init.service --no-pager 2>/dev/null |
     grep -q 'DataSourceNone'; then
    touch /etc/cloud/cloud-init.disabled
    systemctl disable \
        cloud-init-local.service \
        cloud-init.service \
        cloud-config.service \
        cloud-final.service 2>/dev/null || true
    systemctl mask \
        cloud-init-local.service \
        cloud-init.service \
        cloud-config.service \
        cloud-final.service 2>/dev/null || true
fi

systemctl daemon-reload
udevadm control --reload-rules
systemctl reset-failed

echo "========== RESTART AND VERIFY NOW =========="
systemctl restart pulsar-kiosk.service

for _ in $(seq 1 80); do
    if curl -fsS --max-time 1 \
        http://127.0.0.1:4173/health >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

curl -fsS http://127.0.0.1:4173/health
echo

DISPLAY=:0 "$ROOT/core/scripts/configure-displays.sh" \
    >>"$ROOT/core/data/pulsar.log" 2>&1 || true

echo
echo "========== PRE-REBOOT HARDWARE TRUTH =========="

camera_count=0
slow_camera_count=0

for dev in /sys/bus/usb/devices/*; do
    [[ -r "$dev/idVendor" && -r "$dev/idProduct" ]] || continue
    vendor="$(<"$dev/idVendor")"
    product="$(<"$dev/idProduct")"

    if [[ "$vendor:$product" == "2ba2:4d55" ]]; then
        camera_count=$((camera_count + 1))
        speed="$(cat "$dev/speed" 2>/dev/null || echo unknown)"
        serial="$(cat "$dev/serial" 2>/dev/null || echo unknown)"
        echo "CAMERA path=$(basename "$dev") serial=$serial speed=${speed}M"
        case "$speed" in
            5000|10000|20000) ;;
            *) slow_camera_count=$((slow_camera_count + 1)) ;;
        esac
    fi
done

touch_bootloader=0
for dev in /sys/bus/usb/devices/*; do
    [[ -r "$dev/idVendor" && -r "$dev/idProduct" ]] || continue
    if [[ "$(cat "$dev/idVendor"):$(cat "$dev/idProduct")" == "4348:55e0" ]]; then
        touch_bootloader=1
        echo "TOUCH_BOOTLOADER path=$(basename "$dev") id=4348:55e0"
    fi
done

echo "CAMERA_COUNT=$camera_count"
echo "SLOW_CAMERA_COUNT=$slow_camera_count"
echo "TOUCH_BOOTLOADER=$touch_bootloader"
echo "BACKUP=$BACKUP"

echo
echo "A reboot will start in 3 seconds."
nohup bash -c 'sleep 3; systemctl reboot' \
    >/tmp/pulsar-root-repair-reboot.log 2>&1 &
REMOTE

chmod +x /tmp/pulsar-root-repair-remote.sh

scp /tmp/pulsar-root-repair-remote.sh \
    "${REMOTE_USER}@${REMOTE_HOST}:/tmp/pulsar-root-repair-remote.sh"

echo
echo "The next prompt is the sudo password for user ${REMOTE_USER} on the server."

ssh -t "${REMOTE_USER}@${REMOTE_HOST}" \
    'sudo bash /tmp/pulsar-root-repair-remote.sh'

echo
echo "========== WAIT FOR REBOOT =========="

for _ in $(seq 1 60); do
    if ! ssh \
        -o BatchMode=yes \
        -o ConnectTimeout=2 \
        "${REMOTE_USER}@${REMOTE_HOST}" true \
        >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

for _ in $(seq 1 180); do
    if ssh \
        -o BatchMode=yes \
        -o ConnectTimeout=2 \
        "${REMOTE_USER}@${REMOTE_HOST}" true \
        >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

echo
echo "========== POST-REBOOT VERIFICATION =========="

ssh "${REMOTE_USER}@${REMOTE_HOST}" 'bash -s' <<'POST' 2>&1 | tee "$LOCAL_REPORT"
set +e
ROOT=/home/matin/Pulsar-Cpp-Core
export DISPLAY=:0

echo "========== BOOT TIME =========="
systemd-analyze time
echo
systemd-analyze blame --no-pager | head -n 30

echo
echo "========== UNFINISHED OR FAILED JOBS =========="
systemctl --failed --no-pager
systemctl list-jobs --no-pager

echo
echo "========== PULSAR =========="
systemctl --no-pager --full status pulsar-kiosk.service | head -n 45
echo
curl -fsS http://127.0.0.1:4173/health
echo

echo
echo "========== DISPLAYS =========="
xrandr --query |
grep -E '^(HDMI-2|DP-1-1|HDMI-1-0) connected'

echo
echo "========== CAMERAS BY SYSFS =========="
camera_count=0
superspeed_count=0

for dev in /sys/bus/usb/devices/*; do
    [ -r "$dev/idVendor" ] || continue
    [ -r "$dev/idProduct" ] || continue

    vendor="$(cat "$dev/idVendor")"
    product="$(cat "$dev/idProduct")"

    if [ "$vendor:$product" = "2ba2:4d55" ]; then
        camera_count=$((camera_count + 1))
        speed="$(cat "$dev/speed" 2>/dev/null || echo unknown)"
        serial="$(cat "$dev/serial" 2>/dev/null || echo unknown)"
        echo "path=$(basename "$dev") serial=$serial speed=${speed}M"

        case "$speed" in
            5000|10000|20000)
                superspeed_count=$((superspeed_count + 1))
                ;;
        esac
    fi
done

echo "CAMERA_COUNT=$camera_count"
echo "SUPERSPEED_CAMERA_COUNT=$superspeed_count"

echo
echo "========== CAMERA RUNTIME =========="
grep -E \
'^(Left|Right) Camera: (latency-stats|GXOpenDevice failed)' \
"$ROOT/core/data/pulsar.log" |
tail -n 20

echo
echo "========== TOUCH =========="
touch_bootloader=0

for dev in /sys/bus/usb/devices/*; do
    [ -r "$dev/idVendor" ] || continue
    [ -r "$dev/idProduct" ] || continue

    if [ "$(cat "$dev/idVendor"):$(cat "$dev/idProduct")" = "4348:55e0" ]; then
        touch_bootloader=1
        echo "TOUCH_BOOTLOADER=1 path=$(basename "$dev")"
    fi
done

[ "$touch_bootloader" -eq 1 ] || echo "TOUCH_BOOTLOADER=0"
xinput --list | grep -Ei 'touch|USB2IIC|wch' || true

echo
echo "========== CURRENT-BOOT IMPORTANT ERRORS =========="
journalctl -b 0 -p err --no-pager |
grep -Ev 'VMX .*disabled by BIOS|SGX disabled by BIOS' |
tail -n 100

echo
echo "========== RESULT =========="

if systemctl list-jobs --no-legend 2>/dev/null | grep -q .; then
    echo "SOFTWARE_BOOT_COMPLETE=0"
else
    echo "SOFTWARE_BOOT_COMPLETE=1"
fi

if curl -fsS --max-time 2 \
    http://127.0.0.1:4173/health >/dev/null 2>&1; then
    echo "PULSAR_HEALTH=1"
else
    echo "PULSAR_HEALTH=0"
fi

if [ "$camera_count" -eq 2 ] && [ "$superspeed_count" -eq 2 ]; then
    echo "CAMERA_HARDWARE_OK=1"
else
    echo "CAMERA_HARDWARE_OK=0"
    echo "ACTION: Both Daheng cameras must use separate working USB3 SuperSpeed links."
    echo "Move/replace the cable currently falling back to USB2 or failing on usb2-port2."
fi

if [ "$touch_bootloader" -eq 1 ]; then
    echo "TOUCH_HARDWARE_OK=0"
    echo "ACTION: The WCH controller needs its exact original firmware or replacement."
else
    echo "TOUCH_HARDWARE_OK=1"
fi
POST

echo
echo "========== COMPLETE =========="
echo "Post-reboot report:"
echo "$LOCAL_REPORT"
echo
echo "Software boot blockers were repaired and the changes are now part of ./run.sh."
echo "Hardware faults, if still listed in the report, require the stated cable/firmware repair."
