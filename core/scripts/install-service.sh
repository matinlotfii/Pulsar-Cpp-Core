#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_config
if [[ $EUID -ne 0 ]]; then exec sudo -E "$0" "$@"; fi
run_user="${SUDO_USER:-$(stat -c '%U' "$PULSAR_ROOT")}"
if [[ -z "$run_user" || "$run_user" == "root" ]]; then
  run_user="${PULSAR_RUN_USER:-root}"
fi
unit=/etc/systemd/system/pulsar-kiosk.service
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
systemctl daemon-reload
systemctl enable pulsar-kiosk.service
"$PULSAR_ROOT/core/scripts/configure-network-boot.sh" || true
if systemctl is-enabled --quiet display-manager.service 2>/dev/null; then
  systemctl disable --now display-manager.service || true
fi
systemctl disable --now getty@tty1.service 2>/dev/null || true
log "Installed pulsar-kiosk.service for user $run_user."
