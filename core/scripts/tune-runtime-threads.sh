#!/usr/bin/env bash
set -Eeuo pipefail

pid="${1:-$(pgrep -xo pulsar-core || true)}"
[[ -n "$pid" && -d "/proc/$pid/task" ]] || exit 0

# Galaxy, CUDA and OpenGL may create helper threads with their own extreme
# realtime policy. Pulsar's intended camera RR18 and renderer RR16 priorities
# are retained; only priorities above the service's safe ceiling are demoted.
for _ in $(seq 1 50); do
  [[ -d "/proc/$pid/task" ]] || exit 0

  for task in /proc/"$pid"/task/*; do
    tid="${task##*/}"
    info="$(chrt -p "$tid" 2>/dev/null || true)"
    policy="$(sed -n 's/.*policy: //p' <<<"$info" | head -n1)"
    priority="$(sed -n 's/.*priority: //p' <<<"$info" | head -n1)"

    [[ "$policy" == "SCHED_RR" || "$policy" == "SCHED_FIFO" ]] || continue
    [[ "$priority" =~ ^[0-9]+$ ]] || continue

    if ((priority > 32)); then
      chrt -o -p 0 "$tid" 2>/dev/null || true
    fi
  done

  sleep 0.2
done
