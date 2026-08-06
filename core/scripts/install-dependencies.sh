#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_config
if [[ $EUID -ne 0 ]]; then exec sudo -E "$0" "$@"; fi
export DEBIAN_FRONTEND=noninteractive
log "Installing the minimal Ubuntu Server runtime and C++ build packages..."
apt-get update
apt-get install -y --no-install-recommends \
  build-essential cmake ninja-build pkg-config ca-certificates curl git rsync openssh-client \
  libjpeg-dev libsdl2-dev libsdl2-2.0-0 nodejs npm node-typescript xserver-xorg-core xserver-xorg-video-all xinit \
  xserver-xorg-input-libinput openbox x11-xserver-utils xinput unclutter-xfixes ffmpeg usbutils udev \
  network-manager iw rfkill policykit-1 inotify-tools

if ! find_browser >/dev/null 2>&1; then
  log "No kiosk browser found; installing Google Chrome Stable."
  temp_deb="$(mktemp --suffix=.deb)"
  if curl -fL --retry 3 -o "$temp_deb" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb; then
    apt-get install -y "$temp_deb"
  else
    warn "Chrome download failed; trying the Ubuntu Chromium package."
    apt-get install -y chromium-browser || apt-get install -y chromium
  fi
  rm -f "$temp_deb"
fi

install -m 0644 "$PULSAR_ROOT/camera/vendor/galaxy/config/99-galaxy-u3v.rules" /etc/udev/rules.d/99-pulsar-galaxy-u3v.rules
cat >/etc/security/limits.d/90-pulsar-camera.conf <<'LIMITS'
* soft memlock unlimited
* hard memlock unlimited
* soft rtprio 90
* hard rtprio 90
LIMITS
udevadm control --reload-rules || true
udevadm trigger --subsystem-match=usb || true
"$PULSAR_ROOT/core/scripts/configure-network-boot.sh" || true
log "Dependencies installed. No desktop environment or Python package was installed."
