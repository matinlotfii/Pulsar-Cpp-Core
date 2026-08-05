#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_config
refresh_only=0
[[ "${1:-}" == "--refresh" ]] && refresh_only=1
if [[ $EUID -ne 0 ]]; then exec sudo -E "$0" "$@"; fi
run_user="${PULSAR_RUN_USER:-${SUDO_USER:-$(stat -c '%U' "$PULSAR_ROOT")}}"
if [[ -z "$run_user" || "$run_user" == "root" ]]; then
  run_user="${PULSAR_RUN_USER:-root}"
fi
unit=/etc/systemd/system/pulsar-kiosk.service
dropin_dir=/etc/systemd/system/pulsar-kiosk.service.d
touch_unit=/etc/systemd/system/pulsar-touch-hotplug.service
touch_rule=/etc/udev/rules.d/99-pulsar-touch-hotplug.rules
cat >"$unit" <<UNIT
[Unit]
Description=Pulsar Exoscope C++ Kiosk
After=systemd-user-sessions.service
Conflicts=display-manager.service getty@tty1.service

[Service]
Type=simple
Environment=PULSAR_RUN_USER=$run_user
WorkingDirectory=$PULSAR_ROOT
ExecStart=/usr/bin/xinit $PULSAR_ROOT/core/scripts/xsession.sh -- :0 vt1 -keeptty -nolisten tcp
Restart=on-failure
RestartSec=2
StandardInput=tty
StandardOutput=journal
StandardError=journal
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes

[Install]
WantedBy=multi-user.target
UNIT

# PULSAR_BOUNDED_TOUCH_UNIT_V3
cat >"$touch_unit" <<UNIT
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
UNIT

mkdir -p "$dropin_dir"
cat >"$dropin_dir/90-pulsar-managed.conf" <<DROPIN
[Unit]
Wants=nvidia-persistenced.service
After=systemd-user-sessions.service nvidia-persistenced.service

[Service]
Environment=PULSAR_ROOT=$PULSAR_ROOT
ExecStartPre=
ExecStartPre=$PULSAR_ROOT/core/scripts/pulsar-boot-preflight.sh
TimeoutStartSec=0
DROPIN

chmod 0755 \
  "$PULSAR_ROOT/core/scripts/pulsar-boot-preflight.sh" \
  "$PULSAR_ROOT/core/scripts/configure-audio.sh" \
  "$PULSAR_ROOT/core/scripts/configure-network-boot.sh" \
  "$PULSAR_ROOT/core/scripts/touch-hotplug-event.sh"

install -m 0644 "$PULSAR_ROOT/core/config/99-pulsar-touch-hotplug.rules" "$touch_rule"

systemctl daemon-reload
systemctl enable pulsar-kiosk.service

# PULSAR_ALWAYS_REFRESH_TOUCH_V2
# Touch rules and HID modules must also be refreshed during normal deploys.
modprobe usbhid 2>/dev/null || true
modprobe hid_multitouch 2>/dev/null || true
# PULSAR_SAFE_TOUCH_REFRESH_V3
udevadm control --reload-rules || true
udevadm trigger --subsystem-match=input --action=add || true
timeout 8 systemctl start pulsar-touch-hotplug.service || true

if ((refresh_only == 0)); then
  "$PULSAR_ROOT/core/scripts/configure-network-boot.sh" || true
fi

if systemctl is-enabled --quiet display-manager.service 2>/dev/null; then
  systemctl disable --now display-manager.service || true
fi
systemctl disable --now getty@tty1.service 2>/dev/null || true
log "Installed/refreshed pulsar-kiosk.service for user $run_user at $PULSAR_ROOT."
