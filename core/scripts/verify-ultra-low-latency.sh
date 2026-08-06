#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
API="http://127.0.0.1:4173/api/cameras"
LOG="$ROOT/core/data/pulsar.log"
OUT_DIR="$ROOT/core/data/latency-reports"
mkdir -p "$OUT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$OUT_DIR/verify-$STAMP.txt"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

{
  echo "PULSAR ULTRA LOW LATENCY VERIFY"
  echo "timestamp=$(date --iso-8601=seconds)"
  echo "host=$(hostname)"
  echo

  ready=0
  for _ in $(seq 1 40); do
    json="$(curl -fsS --max-time 2 "$API" 2>/dev/null || true)"
    online="$(grep -o '"online":true' <<<"$json" | wc -l || true)"
    if [[ "$online" -ge 2 ]]; then ready=1; break; fi
    sleep 0.5
  done
  [[ "$ready" == 1 ]] || { echo "STATUS=FAIL cameras-not-online"; exit 21; }

  # Warm counters, then take 12 low-rate API samples. This has no per-frame cost.
  sleep 6
  for _ in $(seq 1 12); do
    curl -fsS --max-time 2 "$API" >>"$TMP" 2>/dev/null || true
    printf '\n' >>"$TMP"
    sleep 1
  done

  python3 - "$TMP" <<'PY'
import json, statistics, sys
left=[]; right=[]
for line in open(sys.argv[1], encoding='utf-8'):
    try: p=json.loads(line)
    except Exception: continue
    c=p.get('cameras', [])
    if len(c)>=2 and c[0].get('online') and c[1].get('online'):
        left.append(float(c[0].get('fps',0)))
        right.append(float(c[1].get('fps',0)))
if not left or not right:
    print('CAMERA_STATUS=FAIL_NO_SAMPLES')
    raise SystemExit(22)
l=statistics.median(left); r=statistics.median(right)
print(f'LEFT_FPS_MEDIAN={l:.3f}')
print(f'RIGHT_FPS_MEDIAN={r:.3f}')
print(f'FPS_DELTA={abs(l-r):.3f}')
print('CAMERA_STATUS=' + ('PASS' if min(l,r)>=29.0 else 'FAIL_LOW_FPS'))
if min(l,r)<29.0: raise SystemExit(23)
PY

  echo
  echo "LATEST_PIPELINE_SAMPLES:"
  samples="$(tail -n 3000 "$LOG" 2>/dev/null | grep -aE 'Left Camera: latency-stats|Right Camera: latency-stats|SBS Renderer: latency-stats' | tail -n 30 || true)"
  printf '%s\n' "$samples"
  [[ -n "$samples" ]] || { echo "PIPELINE_STATUS=FAIL_NO_TELEMETRY"; exit 24; }

  printf '%s\n' "$samples" | python3 -c '
import re,statistics,sys
text=sys.stdin.read().splitlines()
vals={k:[] for k in ("raw","h2d","gpu","publish","upload","age","skew","present")}
for s in text:
 def get(n):
  m=re.search(rf"{re.escape(n)}=([0-9.]+)",s); return float(m.group(1)) if m else None
 if "Camera: latency-stats" in s:
  for key,name in (("raw","raw-copy-ms"),("h2d","gpu-h2d-ms"),("gpu","gpu-total-ms"),("publish","publish-ms")):
   v=get(name)
   if v is not None: vals[key].append(v)
 if "SBS Renderer: latency-stats" in s:
  for key,name in (("upload","texture-upload-ms"),("skew","stereo-host-skew-ms"),("present","present-ms")):
   v=get(name)
   if v is not None: vals[key].append(v)
  a=[get("left-host-age-ms"),get("right-host-age-ms")]
  vals["age"] += [x for x in a if x is not None]
for k,a in vals.items():
 if a: print(f"{k.upper()}_MS_MEDIAN={statistics.median(a):.3f}")
raw=statistics.median(vals["raw"]) if vals["raw"] else 999
h2d=statistics.median(vals["h2d"]) if vals["h2d"] else 999
age=statistics.median(vals["age"]) if vals["age"] else 999
upload=statistics.median(vals["upload"]) if vals["upload"] else 999
ok = raw < 3.0 and h2d < 3.0 and age < 70.0 and upload < 10.0
print("PIPELINE_STATUS=" + ("PASS" if ok else "FAIL_THRESHOLD"))
if not ok: raise SystemExit(25)
'

  echo
  echo "PROCESS_COUNTS:"
  echo "pulsar_core=$(pgrep -xc pulsar-core 2>/dev/null || true)"
  echo "xinit=$(pgrep -xc xinit 2>/dev/null || true)"
  echo "xorg=$(pgrep -xc Xorg 2>/dev/null || true)"
  [[ "$(pgrep -xc pulsar-core 2>/dev/null || true)" == 1 ]] || exit 26
  echo "STATUS=PASS"
} 2>&1 | tee "$REPORT"

echo "REPORT=$REPORT"
