#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_config
if [[ "${PULSAR_SMOKE_SKIP_BUILD:-0}" != "1" ]]; then
  "$PULSAR_ROOT/core/scripts/build-ui.sh"
  "$PULSAR_ROOT/core/scripts/build-cpp.sh" >/dev/null
fi
port=4197
test_dir="$(mktemp -d)"
cleanup() {
  if [[ -n "${pid:-}" ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -rf "$test_dir"
}
trap cleanup EXIT

PULSAR_CAMERA_MODE=mock PULSAR_HEADLESS=1 PULSAR_PORT=$port \
  "$PULSAR_BINARY" --ui-root "$PULSAR_ROOT/ui/dist" --data-root "$test_dir/data" >"$test_dir/core.log" 2>&1 &
pid=$!
for _ in $(seq 1 100); do
  curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1 && break
  sleep .1
done

curl -fsS "http://127.0.0.1:$port/health" | grep -q '"ok":true'
curl -fsS "http://127.0.0.1:$port/api/state" | grep -q 'Pulsar Mock Camera'
curl -fsS -X POST -H 'Content-Type: application/json' \
  -d '{"zoom":2.5,"brightness":72,"rotation":90,"frozen":true}' \
  "http://127.0.0.1:$port/api/camera/0" | grep -q '"zoom":2.50'
curl -fsS -X POST -H 'Content-Type: application/json' \
  -d '{"swapEyes":true,"gapPx":18,"mirrorRight":true}' \
  "http://127.0.0.1:$port/api/display" | grep -q '"swapEyes":true'
curl -fsS -X POST -H 'Content-Type: application/json' \
  -d '{"motor0":125,"motor5":-80}' \
  "http://127.0.0.1:$port/api/robot" | grep -q '"motors":\[125,0,0,0,0,-80\]'

curl -fsS "http://127.0.0.1:$port/camera/0/frame.jpg" -o "$test_dir/frame.jpg"
file "$test_dir/frame.jpg" | grep -q 'JPEG image data'
curl -fsS -X POST -H 'Content-Type: application/json' -d '{}' \
  "http://127.0.0.1:$port/api/recording/snapshot" | grep -q '"file":"'
find "$test_dir/data/recordings" -name '*.jpg' -size +1k | grep -q .

curl -fsS -X POST -H 'Content-Type: application/json' -d '{}' \
  "http://127.0.0.1:$port/api/recording/start" | grep -q '"active":true'
sleep 2
curl -fsS -X POST -H 'Content-Type: application/json' -d '{}' \
  "http://127.0.0.1:$port/api/recording/stop" | grep -q '"active":false'
video="$(find "$test_dir/data/recordings" -name '*.mp4' -size +10k -print -quit)"
[[ -n "$video" ]]
ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$video" | grep -q 'h264'

curl -fsS "http://127.0.0.1:$port/" | grep -q 'Pulsar HMI'
if command -v node >/dev/null 2>&1; then
  find "$PULSAR_ROOT/ui/dist" -name '*.js' -print0 | xargs -0 -n1 node --check >/dev/null
fi
# Python is intentionally used only by the X11 SBS window-placement helper.
# Bytecode/cache files are build artifacts and must never enter a checkpoint.
find "$PULSAR_ROOT" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
unexpected_python="$({
  find "$PULSAR_ROOT" -type f -name '*.py'     ! -path "$PULSAR_ROOT/core/scripts/place-sbs-window.py" -print
} | head -n 1)"
[[ -z "$unexpected_python" ]] || die "Unexpected Python source remains: $unexpected_python"

kill "$pid"
wait "$pid"
pid=""
log "Smoke test passed: C++/UI build, mock cameras, API, live settings, JPEG, snapshot and H.264 recording."
