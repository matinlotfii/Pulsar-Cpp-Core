#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_config

if [[ $EUID -ne 0 ]]; then
  exec sudo -E "$0" "$@"
fi

mkdir -p /etc/systemd/system/pulsar-kiosk.service.d
cat >/etc/systemd/system/pulsar-kiosk.service.d/override.conf <<'UNIT'
[Unit]
After=
Wants=
After=systemd-user-sessions.service
UNIT

systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
systemctl mask NetworkManager-wait-online.service 2>/dev/null || true
systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true
systemctl enable NetworkManager.service 2>/dev/null || true
systemctl daemon-reload

log "Disabled wait-online boot blockers and installed Pulsar kiosk unit override."
