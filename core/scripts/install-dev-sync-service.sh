#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_FILE="$UNIT_DIR/pulsar-dev-sync.service"

mkdir -p "$UNIT_DIR"

cat >"$UNIT_FILE" <<UNIT
[Unit]
Description=Pulsar realtime sync to remote Ubuntu server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$ROOT
ExecStart=/usr/bin/env bash $ROOT/core/scripts/dev-sync.sh
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
printf 'Installed %s\n' "$UNIT_FILE"
printf 'Start with: systemctl --user enable --now pulsar-dev-sync.service\n'
