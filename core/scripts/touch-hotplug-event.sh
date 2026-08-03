#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_config

lock_file="/run/pulsar-touch-hotplug.lock"
mkdir -p "$(dirname "$lock_file")"
exec 9>"$lock_file"
flock -n 9 || exit 0

run_user="${PULSAR_RUN_USER:-$(stat -c '%U' "$PULSAR_ROOT")}"
if [[ -z "$run_user" || "$run_user" == "root" ]]; then
  run_user="${SUDO_USER:-root}"
fi
[[ -n "$run_user" ]] || exit 0

user_home="$(getent passwd "$run_user" | cut -d: -f6)"
[[ -n "$user_home" ]] || user_home="/home/$run_user"
xauthority="$user_home/.Xauthority"
xdg_runtime_dir="/tmp/pulsar-runtime-$run_user"

mkdir -p "$xdg_runtime_dir"
chown "$run_user":"$(id -gn "$run_user")" "$xdg_runtime_dir"
chmod 700 "$xdg_runtime_dir"

udevadm settle --timeout="${PULSAR_TOUCH_UDEV_SETTLE_TIMEOUT_SEC:-5}" 2>/dev/null || true

env_args=(
  DISPLAY="${DISPLAY:-:0}"
  XDG_RUNTIME_DIR="$xdg_runtime_dir"
  HOME="$user_home"
  USER="$run_user"
  LOGNAME="$run_user"
)
if [[ -f "$xauthority" ]]; then
  env_args+=(XAUTHORITY="$xauthority")
fi

run_as_user() {
  runuser -u "$run_user" -- env "${env_args[@]}" "$@"
}

wait_attempts="${PULSAR_TOUCH_X11_READY_ATTEMPTS:-20}"
wait_interval="${PULSAR_TOUCH_X11_READY_INTERVAL_SEC:-1}"
for _ in $(seq 1 "$wait_attempts"); do
  if run_as_user xset q >/dev/null 2>&1; then
    run_as_user \
      "$PULSAR_ROOT/core/scripts/configure-touch.sh" --watch --attempts 15 --interval 1
    exit $?
  fi
  sleep "$wait_interval"
done

warn "Touch hotplug event could not reach the X11 session on ${DISPLAY:-:0}; skipping this trigger."
exit 0
