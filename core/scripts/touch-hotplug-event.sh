#!/usr/bin/env bash
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
