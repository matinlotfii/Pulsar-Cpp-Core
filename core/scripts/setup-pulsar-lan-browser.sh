#!/usr/bin/env bash
set -euo pipefail

TARGET="192.168.1.123"
PORT="4173"

LAN_IF="$(
  ip -o -4 addr show up scope global |
  awk '$4 ~ /^192\.168\.1\./ {print $2; exit}'
)"

if [[ -z "$LAN_IF" ]]; then
  echo "ERROR: اتصال شبکه 192.168.1.x پیدا نشد."
  exit 1
fi

LAN_SRC="$(
  ip -o -4 addr show dev "$LAN_IF" scope global |
  awk '$4 ~ /^192\.168\.1\./ {
    sub(/\/.*/, "", $4)
    print $4
    exit
  }'
)"

echo "[Pulsar] LAN interface: $LAN_IF"
echo "[Pulsar] LAN address:   $LAN_SRC"

# مسیر دائمی مستقیم به Pulsar؛ مسیر VPN را برای این IP دور می‌زند.
sudo tee /usr/local/sbin/pulsar-lan-route >/dev/null <<'ROUTE'
#!/usr/bin/env bash
set -euo pipefail

TARGET="192.168.1.123"

LAN_IF="$(
  ip -o -4 addr show up scope global |
  awk '$4 ~ /^192\.168\.1\./ {print $2; exit}'
)"

[[ -n "$LAN_IF" ]] || exit 0

LAN_SRC="$(
  ip -o -4 addr show dev "$LAN_IF" scope global |
  awk '$4 ~ /^192\.168\.1\./ {
    sub(/\/.*/, "", $4)
    print $4
    exit
  }'
)"

[[ -n "$LAN_SRC" ]] || exit 0

ip route replace "$TARGET/32" \
  dev "$LAN_IF" \
  src "$LAN_SRC" \
  metric 5
ROUTE

sudo chmod 755 /usr/local/sbin/pulsar-lan-route

# بعد از روشن‌شدن شبکه یا VPN مسیر دوباره اعمال می‌شود.
sudo install -d -m 755 /etc/NetworkManager/dispatcher.d

sudo tee /etc/NetworkManager/dispatcher.d/90-pulsar-lan-route >/dev/null <<'DISPATCHER'
#!/bin/sh
/usr/local/sbin/pulsar-lan-route >/dev/null 2>&1 || true
DISPATCHER

sudo chmod 755 /etc/NetworkManager/dispatcher.d/90-pulsar-lan-route
sudo /usr/local/sbin/pulsar-lan-route

# پروفایل جداگانه Firefox بدون Proxy و افزونه‌های VPN.
if command -v snap >/dev/null 2>&1 &&
   snap list firefox >/dev/null 2>&1; then
  PROFILE="$HOME/snap/firefox/common/pulsar-lan-profile"
else
  PROFILE="$HOME/.local/share/pulsar-firefox-profile"
fi

mkdir -p "$PROFILE"

cat > "$PROFILE/user.js" <<'FIREFOX'
user_pref("network.proxy.type", 0);
user_pref("network.proxy.no_proxies_on", "localhost, 127.0.0.1, 192.168.1.123");
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage", "http://192.168.1.123:4173/");
user_pref("browser.startup.page", 1);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
FIREFOX

mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/pulsar-ui" <<EOF
#!/usr/bin/env bash
sudo -n /usr/local/sbin/pulsar-lan-route >/dev/null 2>&1 || true
exec firefox \
  --no-remote \
  --profile "$PROFILE" \
  "http://$TARGET:$PORT/"
EOF
chmod 755 "$HOME/.local/bin/pulsar-ui"

mkdir -p "$HOME/.local/share/applications"
cat > "$HOME/.local/share/applications/pulsar-ui.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Pulsar UI
Comment=Open Pulsar server UI directly over LAN
Exec=$HOME/.local/bin/pulsar-ui
Terminal=false
Categories=Development;Network;
StartupNotify=true
EOF
chmod 755 "$HOME/.local/share/applications/pulsar-ui.desktop"

echo "===== ROUTE ====="
ip route get "$TARGET"

echo "===== SERVER TEST ====="
curl --noproxy '*' \
  --max-time 5 \
  "http://$TARGET:$PORT/health"

echo
echo "[Pulsar] نصب کامل شد."
echo "[Pulsar] Launcher: $HOME/.local/bin/pulsar-ui"
