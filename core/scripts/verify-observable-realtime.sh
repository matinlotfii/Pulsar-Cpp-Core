#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/core/scripts/common.sh"
load_config
BASE_URL="http://127.0.0.1:${PULSAR_PORT:-4173}"

base_status=0
"$ROOT/core/scripts/verify-fullquality-realtime.sh" || base_status=$?

echo
echo "PULSAR OBSERVABLE REALTIME V9 VERIFICATION"
echo "=========================================="

motion_ok=0
telemetry_source_ok=0
telemetry_endpoint_ok=0
viewer_ok=0
glasses_ok=0

css="$ROOT/ui/frontend/src/styles/global.css"
main="$ROOT/ui/frontend/src/main.tsx"
telemetry="$ROOT/ui/frontend/src/app/runtime-telemetry.ts"
stream="$ROOT/ui/frontend/src/app/camera-stream.tsx"

if [[ -f "$css" ]] &&
   grep -q 'PULSAR_OBSERVABLE_REALTIME_UI_V9' "$css" &&
   ! grep -q 'html\.pulsar-realtime-ui \*.*animation-duration: 0\.001ms' "$css" &&
   grep -q 'pulsar-motion-enabled' "$main"; then
  motion_ok=1
fi

if [[ -f "$telemetry" && -f "$stream" ]] &&
   grep -q 'startRuntimeTelemetry' "$main" &&
   grep -q 'recordPreviewTelemetry' "$stream" &&
   grep -q 'requestAnimationFrame(drawLatest)' "$stream"; then
  telemetry_source_ok=1
fi

payload='{"windowMs":1000,"rafFps":60,"rafMisses":0,"rafGapMaxMs":17,"longTasks":0,"longTaskMs":0,"stateApiMs":1,"leftSamples":1,"leftRequestMs":1,"leftSourceAgeMs":1,"leftDecodeMs":1,"leftDrawMs":1,"leftDropped":0,"rightSamples":1,"rightRequestMs":1,"rightSourceAgeMs":1,"rightDecodeMs":1,"rightDrawMs":1,"rightDropped":0}'
if curl -fsS --max-time 3 -X POST -H 'Content-Type: application/json' \
    --data "$payload" "$BASE_URL/api/telemetry/ui" | grep -q '"ok":true'; then
  telemetry_endpoint_ok=1
fi

panel_output="$(DISPLAY="${DISPLAY:-:0}" "$ROOT/core/scripts/verify-viewer-panels.py" 2>&1)" || viewer_status=$?
viewer_status="${viewer_status:-0}"
printf '%s\n' "$panel_output"
((viewer_status == 0)) && viewer_ok=1

connected_glasses=0
if [[ -f "$PULSAR_DATA_DIR/displays.env" ]]; then
  connected_glasses="$(awk -F= '/^PULSAR_ROLE_AR[12]_CONNECTED=/{sum+=$2}END{print sum+0}' "$PULSAR_DATA_DIR/displays.env")"
fi
required_glasses="${PULSAR_VERIFY_REQUIRE_GLASS_COUNT:-1}"
if ((connected_glasses >= required_glasses)); then
  glasses_ok=1
fi

printf 'UI_MOTION=%s selective compositor-friendly animations enabled\n' "$([[ "$motion_ok" == 1 ]] && echo PASS || echo FAIL)"
printf 'UI_TELEMETRY_SOURCE=%s worker/canvas/rAF instrumentation\n' "$([[ "$telemetry_source_ok" == 1 ]] && echo PASS || echo FAIL)"
printf 'UI_TELEMETRY_ENDPOINT=%s POST /api/telemetry/ui\n' "$([[ "$telemetry_endpoint_ok" == 1 ]] && echo PASS || echo FAIL)"
printf 'VIEWER_PANELS=%s actual X11 viewer geometry and pixels\n' "$([[ "$viewer_ok" == 1 ]] && echo PASS || echo FAIL)"
printf 'GLASSES_CONNECTED=%s connected=%s required=%s\n' "$([[ "$glasses_ok" == 1 ]] && echo PASS || echo FAIL)" "$connected_glasses" "$required_glasses"

failed=()
((base_status == 0)) || failed+=(BASE_REALTIME)
((motion_ok == 1)) || failed+=(UI_MOTION)
((telemetry_source_ok == 1)) || failed+=(UI_TELEMETRY_SOURCE)
((telemetry_endpoint_ok == 1)) || failed+=(UI_TELEMETRY_ENDPOINT)
((viewer_ok == 1)) || failed+=(VIEWER_PANELS)
((glasses_ok == 1)) || failed+=(GLASSES_CONNECTED)

if ((${#failed[@]})); then
  echo "OBSERVABLE_REALTIME_STATUS=FAIL"
  printf 'FAILED_CHECKS=%s\n' "$(IFS=,; echo "${failed[*]}")"
  exit 1
fi

echo "OBSERVABLE_REALTIME_STATUS=PASS"
