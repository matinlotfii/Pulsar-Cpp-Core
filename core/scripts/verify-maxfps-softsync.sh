#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$ROOT/core/data/pulsar.log"
API="http://127.0.0.1:4173/api/cameras"

echo
echo "========== MAX FPS + SOFTWARE SYNC VERIFY =========="
json=""
for _ in $(seq 1 30); do
  json="$(curl -fsS --max-time 2 "$API" 2>/dev/null || true)"
  online="$(grep -o '"online":true' <<<"$json" | wc -l || true)"
  [[ "$online" -ge 2 ]] && break
  sleep 1
done

# Let one-second FPS counters and two-second latency counters settle.
sleep 8
samples_file="$(mktemp)"
trap 'rm -f "$samples_file"' EXIT
for _ in $(seq 1 5); do
  curl -fsS --max-time 2 "$API" >>"$samples_file" 2>/dev/null || true
  printf '\n' >>"$samples_file"
  sleep 1
done

python3 - "$samples_file" <<'PYVERIFY'
import json,statistics,sys
left=[]; right=[]; last=None
for line in open(sys.argv[1], encoding='utf-8'):
    line=line.strip()
    if not line: continue
    try: payload=json.loads(line)
    except Exception: continue
    cams=payload.get('cameras',[])
    if len(cams)>=2 and cams[0].get('online') and cams[1].get('online'):
        left.append(float(cams[0].get('fps',0.0)))
        right.append(float(cams[1].get('fps',0.0)))
        last=payload
print(json.dumps(last or {}, ensure_ascii=False))
if left and right:
    l=statistics.median(left); r=statistics.median(right)
    print(f'CAMERA_FPS_MEDIAN={l:.2f},{r:.2f}')
    print(f'CAMERA_FPS_DELTA={abs(l-r):.2f}')
    if min(l,r) >= 29.0:
        print('MAX_FPS_STATUS=PASS')
    elif min(l,r) >= 26.0:
        print('MAX_FPS_STATUS=NEAR_MAX_CHECK_USB_OR_EXPOSURE')
    else:
        print('MAX_FPS_STATUS=LOW')
else:
    print('MAX_FPS_STATUS=NO_TWO_CAMERA_SAMPLES')
PYVERIFY

echo
echo "--- transport/readback ---"
tail -n 1200 "$LOG" 2>/dev/null |
  grep -aE 'maxfps-readback|low-latency stream-buffer-mode=|software-start-sync=' |
  tail -n 24 || true

echo
echo "--- latest latency/sync samples ---"
latest_renderer="$(tail -n 1800 "$LOG" 2>/dev/null | grep -a 'SBS Renderer: latency-stats' | tail -n 1 || true)"
tail -n 1800 "$LOG" 2>/dev/null |
  grep -aE 'Left Camera: latency-stats|Right Camera: latency-stats|SBS Renderer: latency-stats' |
  tail -n 18 || true

if [[ -n "$latest_renderer" ]]; then
  skew="$(sed -n 's/.*stereo-host-skew-ms=\([0-9.]*\).*/\1/p' <<<"$latest_renderer")"
  if [[ -n "$skew" ]]; then
    python3 - "$skew" <<'PYSKEW'
import sys
skew=float(sys.argv[1])
print(f'STEREO_HOST_SKEW_MS={skew:.3f}')
if skew <= 5.0:
    print('SOFTWARE_SYNC_STATUS=GOOD')
elif skew <= 12.0:
    print('SOFTWARE_SYNC_STATUS=ACCEPTABLE')
else:
    print('SOFTWARE_SYNC_STATUS=NEEDS_HARDWARE_TRIGGER_FOR_EXACT_SYNC')
PYSKEW
  fi
else
  echo "SOFTWARE_SYNC_STATUS=NO_RENDERER_SAMPLE"
fi

echo "====================================================="
