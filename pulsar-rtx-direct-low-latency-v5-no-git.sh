#!/usr/bin/env bash
set -Eeuo pipefail

SERVER="${PULSAR_SERVER:-192.168.1.123}"
REMOTE_USER="${PULSAR_REMOTE_USER:-matin}"
REMOTE_ROOT="${PULSAR_REMOTE_ROOT:-/home/matin/Pulsar-Cpp-Core}"
LOCAL_ROOT="${PULSAR_LOCAL_ROOT:-$PWD}"
TS="$(date +%Y%m%d-%H%M%S)"
SOCKET="/tmp/pulsar-throughput395-${USER}-$$"
LOCAL_LOG="$HOME/Downloads/pulsar-throughput395-$TS.log"
REMOTE_SCRIPT="/tmp/pulsar-throughput395-$TS.sh"
REMOTE_PAYLOAD="/tmp/pulsar-throughput395-$TS.tar.gz"
PAYLOAD="/tmp/pulsar-throughput395-$TS.tar.gz"

PROFILES=(
  "camera/profiles/FCU22080658-reference350.txt"
  "camera/profiles/FCU22080659-reference350.txt"
)

cleanup() {
  ssh -S "$SOCKET" -O exit "$REMOTE_USER@$SERVER" >/dev/null 2>&1 || true
  rm -f "$SOCKET" "$PAYLOAD"
}
trap cleanup EXIT

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$(hostname -s 2>/dev/null || hostname)" != "pulsar" ]] ||
  fail "این اسکریپت را روی amin@localhost اجرا کن."

[[ -f "$LOCAL_ROOT/CMakeLists.txt" ]] ||
  fail "اسکریپت را از ریشه پروژه اجرا کن."

cd "$LOCAL_ROOT"

visual_fingerprint() {
  python3 - "$1" <<'PY'
from pathlib import Path
import hashlib
import sys

path = Path(sys.argv[1])
ignored = {
    "DeviceLinkThroughputLimit",
    "StreamBufferHandlingMode",
    "StreamTransferSize",
    "StreamTransferNumberUrb",
    "AcquisitionBufferCachePrec",
}

kept = []
for line in path.read_text(errors="replace").splitlines():
    key = line.split(None, 1)[0] if line.split() else ""
    if key not in ignored:
        kept.append(line)

print(hashlib.sha256(("\n".join(kept) + "\n").encode()).hexdigest())
PY
}

declare -A BEFORE_VISUAL
for rel in "${PROFILES[@]}"; do
  [[ -f "$rel" ]] || fail "پروفایل پیدا نشد: $rel"
  BEFORE_VISUAL["$rel"]="$(visual_fingerprint "$rel")"
done

echo "============================================================"
echo "PULSAR SAFE THROUGHPUT 395 TEST"
echo "Only DeviceLinkThroughputLimit will change."
echo "No Git, no persistent backup, no build."
echo "============================================================"

python3 - "${PROFILES[@]}" <<'PY'
from pathlib import Path
import re
import sys

for name in sys.argv[1:]:
    path = Path(name)
    lines = path.read_text(errors="replace").splitlines()
    output = []
    found = False

    for line in lines:
        if re.match(r"^DeviceLinkThroughputLimit[ \t]+", line):
            output.append("DeviceLinkThroughputLimit\t395000000")
            found = True
        else:
            output.append(line)

    if not found:
        raise SystemExit(f"ERROR: DeviceLinkThroughputLimit missing in {path}")

    path.write_text("\n".join(output).rstrip() + "\n")
    print(f"{path}: DeviceLinkThroughputLimit=395000000")
PY

for rel in "${PROFILES[@]}"; do
  after="$(visual_fingerprint "$rel")"
  [[ "$after" == "${BEFORE_VISUAL[$rel]}" ]] ||
    fail "تنظیم تصویری در $rel تغییر کرده است."
done

tar -C "$LOCAL_ROOT" -czf "$PAYLOAD" "${PROFILES[@]}"

cat > /tmp/pulsar-throughput395-remote.sh <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${PULSAR_ROOT:?}"
PAYLOAD="${PULSAR_PAYLOAD:?}"
TS="${PULSAR_TS:?}"
APP_LOG="$ROOT/core/data/pulsar.log"
TEMP="/tmp/pulsar-throughput395-original-$TS"
WORK="/tmp/pulsar-throughput395-work-$TS"

PROFILES=(
  "camera/profiles/FCU22080658-reference350.txt"
  "camera/profiles/FCU22080659-reference350.txt"
)

cleanup() {
  rm -rf "$TEMP" "$WORK" "$PAYLOAD"
}
trap cleanup EXIT

mkdir -p "$TEMP" "$WORK"

for rel in "${PROFILES[@]}"; do
  [[ -f "$ROOT/$rel" ]] || {
    echo "ERROR: server profile missing: $rel"
    exit 1
  }
  mkdir -p "$TEMP/$(dirname "$rel")"
  cp -a "$ROOT/$rel" "$TEMP/$rel"
done

measure_fps() {
  local file="$1"
  python3 - "$file" <<'PY'
from pathlib import Path
import re
import statistics
import sys

text = Path(sys.argv[1]).read_text(errors="ignore")
values = [
    float(x)
    for x in re.findall(
        r"(?:Left|Right) Camera: latency-stats.*?output-fps=([0-9.]+)",
        text,
    )
]
print(f"{statistics.median(values):.6f}" if values else "0")
PY
}

echo
echo "[1/4] Measuring current FPS for 20 seconds..."

before_line="$(wc -l < "$APP_LOG" 2>/dev/null || echo 0)"
sleep 20
tail -n "+$((before_line + 1))" "$APP_LOG" > "$WORK/before.log" 2>/dev/null || true
before_fps="$(measure_fps "$WORK/before.log")"
echo "BEFORE_MEDIAN_FPS=$before_fps"

echo
echo "[2/4] Installing 395 MB/s profiles..."

tar -C "$WORK" -xzf "$PAYLOAD"

for rel in "${PROFILES[@]}"; do
  grep -q $'^DeviceLinkThroughputLimit\t395000000$' "$WORK/$rel"
  install -m 0644 "$WORK/$rel" "$ROOT/$rel"
done

start_line="$(wc -l < "$APP_LOG" 2>/dev/null || echo 0)"
sudo -n systemctl restart pulsar-kiosk.service

for _ in $(seq 1 100); do
  new_log="$(tail -n "+$((start_line + 1))" "$APP_LOG" 2>/dev/null || true)"
  if systemctl is-active --quiet pulsar-kiosk.service &&
     pgrep -x pulsar-core >/dev/null 2>&1 &&
     [[ "$(grep -c 'configured sensor=4024x3036' <<<"$new_log")" -ge 2 ]] &&
     [[ "$(grep -c 'GPU pipeline ready' <<<"$new_log")" -ge 2 ]]; then
    break
  fi
  sleep 1
done

echo
echo "[3/4] Measuring 395 MB/s FPS for 30 seconds..."

sleep 30
tail -n "+$((start_line + 1))" "$APP_LOG" > "$WORK/after.log" 2>/dev/null || true
after_fps="$(measure_fps "$WORK/after.log")"

echo "AFTER_MEDIAN_FPS=$after_fps"

echo
echo "=== RECENT PERFORMANCE ==="
grep -aE \
  '(Left|Right) Camera: latency-stats pipeline=|SBS Renderer: latency-stats' \
  "$WORK/after.log" | tail -n 24 || true

echo
echo "=== RECENT ERRORS ==="
grep -aEi \
  'GXImportConfigFile failed|required GalaxyView profile|CPU fallback|camera.*timeout|disconnect|reset|usb.*error' \
  "$WORK/after.log" | tail -n 40 || true

echo
echo "[4/4] Deciding whether to keep the change..."

decision="$(python3 - "$before_fps" "$after_fps" <<'PY'
import sys
before = float(sys.argv[1])
after = float(sys.argv[2])
print("KEEP" if after >= max(27.0, before + 0.5) else "REVERT")
PY
)"

if grep -aEqi \
  'GXImportConfigFile failed|required GalaxyView profile|CPU fallback|camera.*timeout|disconnect|reset|usb.*error' \
  "$WORK/after.log"; then
  decision="REVERT"
fi

if [[ "$decision" == "REVERT" ]]; then
  echo "395 MB/s did not provide a stable improvement; reverting to previous profiles."

  for rel in "${PROFILES[@]}"; do
    install -m 0644 "$TEMP/$rel" "$ROOT/$rel"
  done

  sudo -n systemctl restart pulsar-kiosk.service
  echo "FINAL_STATUS=THROUGHPUT395_REVERTED"
  echo "BEFORE_MEDIAN_FPS=$before_fps"
  echo "AFTER_MEDIAN_FPS=$after_fps"
  exit 2
fi

echo
echo "============================================================"
echo "FINAL_STATUS=THROUGHPUT395_ACTIVE"
echo "IMAGE_SETTINGS_CHANGED=NO"
echo "BEFORE_MEDIAN_FPS=$before_fps"
echo "AFTER_MEDIAN_FPS=$after_fps"
echo "DeviceLinkThroughputLimit=395000000"
echo "============================================================"
REMOTE

chmod 700 /tmp/pulsar-throughput395-remote.sh

echo
echo "Connecting to $REMOTE_USER@$SERVER ..."
echo "رمز SSH کاربر matin را یک‌بار وارد کن."

ssh \
  -M -S "$SOCKET" \
  -o ControlPersist=300 \
  -o StrictHostKeyChecking=accept-new \
  -fnN "$REMOTE_USER@$SERVER"

scp -o ControlPath="$SOCKET" \
  "$PAYLOAD" \
  "$REMOTE_USER@$SERVER:$REMOTE_PAYLOAD"

scp -o ControlPath="$SOCKET" \
  /tmp/pulsar-throughput395-remote.sh \
  "$REMOTE_USER@$SERVER:$REMOTE_SCRIPT"

set +e
ssh -o ControlPath="$SOCKET" \
  "$REMOTE_USER@$SERVER" \
  "PULSAR_ROOT='$REMOTE_ROOT' \
   PULSAR_PAYLOAD='$REMOTE_PAYLOAD' \
   PULSAR_TS='$TS' \
   bash '$REMOTE_SCRIPT'" \
  2>&1 | tee "$LOCAL_LOG"
status=${PIPESTATUS[0]}
set -e

echo
echo "Log: $LOCAL_LOG"

if [[ "$status" -eq 2 ]]; then
  echo "تست پایدار نبود و سرور خودکار به تنظیم قبلی برگشت."
  exit 0
fi

exit "$status"