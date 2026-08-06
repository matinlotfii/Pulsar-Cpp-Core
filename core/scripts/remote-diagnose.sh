#!/usr/bin/env bash
set -u
source "$(dirname "$0")/common.sh"
load_config

service="${1:-pulsar-kiosk.service}"
run_root="$PULSAR_ROOT"

section() { printf '\n========== %s ==========\n' "$1"; }
sudo_read() {
  if sudo -n true >/dev/null 2>&1; then sudo -n "$@"; else "$@"; fi
}

section "SERVICE STATUS"
sudo_read systemctl --no-pager --full status "$service" || true

section "SERVICE UNIT"
sudo_read systemctl cat "$service" || true

section "HEALTH AND PORT"
curl -v --max-time 3 "http://127.0.0.1:${PULSAR_PORT:-4173}/health" 2>&1 || true
ss -ltnp 2>/dev/null | grep -E ":${PULSAR_PORT:-4173}([[:space:]]|$)" || true

section "RUNTIME LIBRARIES"
if [[ -x "$PULSAR_BINARY" ]]; then
  LD_LIBRARY_PATH="$PULSAR_GALAXY_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ldd "$PULSAR_BINARY" || true
else
  echo "Missing executable: $PULSAR_BINARY"
fi

section "PROCESSES"
ps -ef | grep -E '[X]org|[p]ulsar-core|[o]penbox|[c]hrome|[c]hromium' || true

section "X11 OUTPUTS"
DISPLAY=:0 XAUTHORITY="${XAUTHORITY:-/home/${PULSAR_RUN_USER:-matin}/.Xauthority}" xrandr --query 2>&1 || true

section "NVIDIA"
nvidia-smi 2>&1 || true

section "USB CAMERAS"
lsusb 2>&1 | grep -Ei '2ba2|daheng|galaxy' || true

section "RECENT JOURNAL"
sudo_read journalctl -u "$service" -b --no-pager -n 220 || true

section "PULSAR LOG"
tail -n 220 "$run_root/core/data/pulsar.log" 2>&1 || true

section "BROWSER LOG"
tail -n 100 "$run_root/core/data/browser.log" 2>&1 || true
