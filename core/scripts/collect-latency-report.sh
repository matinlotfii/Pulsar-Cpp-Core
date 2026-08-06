#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DURATION="${1:-30}"
OUT="$ROOT/core/data/latency-reports"
mkdir -p "$OUT"
STAMP="$(date +%Y%m%d-%H%M%S)"
DIR="$OUT/collect-$STAMP"
mkdir -p "$DIR"
START="$(date --iso-8601=seconds)"
# One API sample per second and existing application telemetry only. No perf,
# tracing, frame dumps, restarts, or per-frame instrumentation.
for _ in $(seq 1 "$DURATION"); do
  printf '%s ' "$(date --iso-8601=ns)" >> "$DIR/cameras.jsonl"
  curl -fsS --max-time 1 http://127.0.0.1:4173/api/cameras >> "$DIR/cameras.jsonl" 2>/dev/null || printf '{}'
  printf '\n' >> "$DIR/cameras.jsonl"
  sleep 1
done
journalctl --no-pager -u pulsar-kiosk.service --since "$START" > "$DIR/journal.txt" 2>/dev/null || true
cp -a "$ROOT/core/config/pulsar.env" "$DIR/" 2>/dev/null || true
cp -a "$ROOT/core/config/pulsar.local.env" "$DIR/" 2>/dev/null || true
ps -eo user,pid,ppid,psr,ni,pri,pcpu,pmem,nlwp,stat,etime,cmd > "$DIR/processes.txt"
lsusb -t > "$DIR/usb-topology.txt" 2>/dev/null || true
nvidia-smi > "$DIR/nvidia-smi.txt" 2>/dev/null || true
"$ROOT/core/scripts/verify-ultra-low-latency.sh" > "$DIR/verify.txt" 2>&1 || true
tar -C "$OUT" -czf "$OUT/collect-$STAMP.tar.gz" "collect-$STAMP"
echo "$OUT/collect-$STAMP.tar.gz"
