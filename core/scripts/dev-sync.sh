#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG_EXAMPLE="$ROOT/core/config/dev-sync.env.example"
CONFIG_FILE="$ROOT/core/config/dev-sync.env"
STATE_DIR="$ROOT/.dev-sync"
LAST_STATE_FILE="$STATE_DIR/last-state.sha256"

log() { printf '\033[1;36m[Pulsar Sync]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[Pulsar Sync]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[Pulsar Sync]\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$STATE_DIR"
[[ -f "$CONFIG_FILE" ]] || cp "$CONFIG_EXAMPLE" "$CONFIG_FILE"
set -a
source "$CONFIG_EXAMPLE"
source "$CONFIG_FILE"
set +a

REMOTE="${SYNC_REMOTE_USER}@${SYNC_REMOTE_HOST}"
SSH_OPTS=(-F /dev/null -p "$SYNC_REMOTE_PORT" -o BatchMode=yes -o ConnectTimeout=12 -o StrictHostKeyChecking=accept-new)
RSYNC_SSH="ssh -F /dev/null -p $SYNC_REMOTE_PORT -o BatchMode=yes -o ConnectTimeout=12 -o StrictHostKeyChecking=accept-new"
RSYNC_ARGS=(-az --delete-delay --delay-updates --omit-dir-times -e "$RSYNC_SSH")
[[ "${SYNC_DELETE:-1}" == "1" ]] || RSYNC_ARGS=(-az --delay-updates -e "$RSYNC_SSH")

EXCLUDES=(
  --exclude=.git/
  --exclude=.pulsar-backups/
  --exclude=run-logs/
  --exclude=.dev-sync/
  --exclude=.codex-tmp/
  --exclude=core/build/
  --exclude=core/data/
  --exclude=node_modules/
  --exclude=ui/frontend/node_modules/
  --exclude=ui/frontend/dist/
  --exclude=ui/frontend/.vite/
  --exclude=ui/frontend/.cache/
)
[[ "${SYNC_INCLUDE_LOCAL_CONFIG:-0}" == "1" ]] || EXCLUDES+=(--exclude=core/config/pulsar.local.env)

ensure_remote_ready() {
  ssh "${SSH_OPTS[@]}" "$REMOTE" "mkdir -p $(printf '%q' "$SYNC_REMOTE_DIR")"
}

run_remote_apply() {
  local root_q service_q
  printf -v root_q '%q' "$SYNC_REMOTE_DIR"
  printf -v service_q '%q' "${SYNC_REMOTE_SERVICE:-pulsar-kiosk.service}"

  local script
  printf -v script 'set -Eeuo pipefail; cd %q' "$SYNC_REMOTE_DIR"
  script+='; chmod +x ./run.sh ./core/scripts/*.sh'
  script+='; export CUDA_HOME=/usr/local/cuda-13.2'
  script+='; export CUDACXX=/usr/local/cuda-13.2/bin/nvcc'
  script+='; export PATH="$CUDA_HOME/bin:$PATH"'
  script+='; test -x "$CUDACXX"'

  if [[ "${SYNC_REMOTE_BUILD_ON_SYNC:-1}" == "1" ]]; then
    if [[ "${SYNC_REMOTE_BUILD_UI_ON_SYNC:-1}" == "1" ]]; then
      script+='; PULSAR_USE_PREBUILT_UI=1 ./core/scripts/build-ui.sh'
    fi
    script+='; PULSAR_REQUIRE_CUDA=1 ./core/scripts/build-cpp.sh'
    script+="; LD_LIBRARY_PATH=${root_q}/camera/vendor/galaxy/lib:\${LD_LIBRARY_PATH:-} ldd ./core/build/pulsar-core > /tmp/pulsar-ldd.txt"
    script+="; if grep -q 'not found' /tmp/pulsar-ldd.txt; then cat /tmp/pulsar-ldd.txt >&2; exit 1; fi"
  fi

  if [[ "${SYNC_REMOTE_RESTART_ON_SYNC:-1}" == "1" ]]; then
    script+="; sudo -n /usr/bin/systemctl reset-failed ${service_q} || true"
    script+="; sudo -n /usr/bin/systemctl restart ${service_q}"
    script+='; ready=0'
    script+='; for _ in $(seq 1 240); do if systemctl is-active --quiet pulsar-kiosk.service && curl -fsS --max-time 1 http://127.0.0.1:4173/health >/dev/null 2>&1; then ready=1; break; fi; sleep 0.5; done'
    script+='; if [[ "$ready" != 1 ]]; then echo "ERROR: service did not become healthy" >&2; systemctl --no-pager --full status pulsar-kiosk.service >&2 || true; journalctl -u pulsar-kiosk.service -n 160 --no-pager >&2 || true; exit 1; fi'
    script+='; cameras_ok=0; cameras_json=""'
    script+='; for _ in $(seq 1 180); do cameras_json=$(curl -fsS --max-time 1 http://127.0.0.1:4173/api/cameras 2>/dev/null || true); online_count=$(printf "%s" "$cameras_json" | grep -o "\"online\":true" | wc -l || true); if [[ "$online_count" -ge 2 ]]; then cameras_ok=1; break; fi; sleep 0.5; done'
    script+='; if [[ "$cameras_ok" != 1 ]]; then echo "ERROR: both cameras did not become online" >&2; printf "%s\n" "$cameras_json" >&2; journalctl -u pulsar-kiosk.service -n 200 --no-pager >&2 || true; exit 1; fi'
    script+='; echo "Pulsar health:"; curl -fsS http://127.0.0.1:4173/health; echo'
    script+='; echo "Pulsar cameras:"; printf "%s\n" "$cameras_json"'
  fi

  ssh "${SSH_OPTS[@]}" "$REMOTE" "bash -lc $(printf '%q' "$script")"
  log "Remote CUDA build, service restart and two-camera verification succeeded."
}

sync_once() {
  ensure_remote_ready
  rsync "${RSYNC_ARGS[@]}" "${EXCLUDES[@]}" "$ROOT"/ "$REMOTE:$SYNC_REMOTE_DIR"/
  log "Synced to $REMOTE:$SYNC_REMOTE_DIR"
  run_remote_apply
}

snapshot_tree() {
  find "$ROOT" \
    -path "$ROOT/.git" -prune -o \
    -path "$ROOT/.dev-sync" -prune -o \
    -path "$ROOT/.pulsar-backups" -prune -o \
    -path "$ROOT/run-logs" -prune -o \
    -path "$ROOT/core/build" -prune -o \
    -path "$ROOT/core/data" -prune -o \
    -path "$ROOT/ui/frontend/node_modules" -prune -o \
    -type f -printf '%P\t%T@\t%s\n' | LC_ALL=C sort | sha256sum | awk '{print $1}'
}

main() {
  if [[ "${1:-}" == "--once" ]]; then
    sync_once
    return
  fi
  local last="" now=""
  [[ -f "$LAST_STATE_FILE" ]] && last="$(<"$LAST_STATE_FILE")"
  while true; do
    sleep "${SYNC_POLL_SECONDS:-2}"
    now="$(snapshot_tree)"
    if [[ "$now" != "$last" ]]; then
      sync_once
      printf '%s' "$now" >"$LAST_STATE_FILE"
      last="$now"
    fi
  done
}
main "$@"
