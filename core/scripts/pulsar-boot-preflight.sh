#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_config

tag="pulsar-boot-preflight"

log_prefight() {
  printf '[%s] %s\n' "$tag" "$*"
  logger -t "$tag" "$*" 2>/dev/null || true
}

count_daheng() {
  local dev count=0
  for dev in /sys/bus/usb/devices/*; do
    [[ -r "$dev/idVendor" ]] || continue
    [[ "$(cat "$dev/idVendor" 2>/dev/null)" == "2ba2" ]] || continue
    count=$((count + 1))
  done
  echo "$count"
}

graphics_ready() {
  if [[ "${PULSAR_BOOT_PREFLIGHT_REQUIRE_NVIDIA:-1}" != "1" ]]; then
    compgen -G '/dev/dri/card*' >/dev/null
    return $?
  fi

  [[ -e /dev/nvidia0 ]] || return 1
  [[ -e /dev/nvidiactl ]] || return 1
  [[ -d /sys/module/nvidia ]] || return 1
  [[ -d /sys/module/nvidia_modeset ]] || return 1
  [[ -d /sys/module/nvidia_drm ]] || return 1
  compgen -G '/dev/dri/card*' >/dev/null || return 1
  compgen -G '/dev/dri/renderD*' >/dev/null || return 1
  timeout "${PULSAR_BOOT_PREFLIGHT_NVIDIA_SMI_TIMEOUT_SEC:-2}s" nvidia-smi >/dev/null 2>&1 || return 1
  return 0
}

enabled="${PULSAR_BOOT_PREFLIGHT_ENABLED:-1}"
required_cameras="${PULSAR_BOOT_PREFLIGHT_REQUIRED_CAMERAS:-2}"
stable_samples_needed="${PULSAR_BOOT_PREFLIGHT_STABLE_SAMPLES:-1}"
sample_interval="${PULSAR_BOOT_PREFLIGHT_SAMPLE_INTERVAL_SEC:-0.25}"
timeout_sec="${PULSAR_BOOT_PREFLIGHT_TIMEOUT_SEC:-4}"
final_delay="${PULSAR_BOOT_PREFLIGHT_FINAL_DELAY_SEC:-0}"

if [[ "$enabled" != "1" ]]; then
  log_prefight "Disabled; continuing without startup delay."
  exit 0
fi

[[ "$required_cameras" =~ ^[0-9]+$ ]] || required_cameras=2
[[ "$stable_samples_needed" =~ ^[1-9][0-9]*$ ]] || stable_samples_needed=2

log_prefight "Starting bounded preflight."

modprobe nvidia 2>/dev/null || true
modprobe nvidia_modeset 2>/dev/null || true
modprobe nvidia_drm 2>/dev/null || true
modprobe nvidia_uvm 2>/dev/null || true

systemctl start nvidia-persistenced.service 2>/dev/null || true
# PULSAR_NO_GLOBAL_UDEV_SETTLE_V3
# Global udev settle waits for every faulty/hotplug USB port. Pulsar checks
# only its own NVIDIA and camera sysfs nodes below.

stable=0
ready=0
deadline=$((SECONDS + timeout_sec))
attempt=0

while ((SECONDS < deadline)); do
  attempt=$((attempt + 1))
  cameras="$(count_daheng)"

  if graphics_ready && ((cameras >= required_cameras)); then
    stable=$((stable + 1))
    log_prefight "Ready sample ${stable}/${stable_samples_needed} (attempt ${attempt}, cameras=${cameras})."
  else
    stable=0
    log_prefight "Not settled yet (attempt ${attempt}, cameras=${cameras})."
  fi

  if ((stable >= stable_samples_needed)); then
    ready=1
    break
  fi

  sleep "$sample_interval"
done

if ((ready == 1)); then
  if [[ "$final_delay" != "0" && "$final_delay" != "0.0" ]]; then
    log_prefight "Readiness reached; applying final quiet interval of ${final_delay}s."
    sleep "$final_delay"
  fi
else
  log_prefight "Readiness timeout reached; continuing with one launch."
fi

log_prefight "Preflight complete; xinit may start."
