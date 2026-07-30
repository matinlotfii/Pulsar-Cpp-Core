#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG_EXAMPLE="$ROOT/core/config/dev-sync.env.example"
CONFIG_FILE="$ROOT/core/config/dev-sync.env"
STATE_DIR="$ROOT/.dev-sync"
LAST_STATE_FILE="$STATE_DIR/last-state.sha256"

log() { printf '\033[1;36m[Pulsar Sync]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[Pulsar Sync]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[Pulsar Sync]\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$STATE_DIR"

if [[ ! -f "$CONFIG_FILE" ]]; then
  cp "$CONFIG_EXAMPLE" "$CONFIG_FILE"
  warn "Created $CONFIG_FILE. Review it once before first sync if needed."
fi

set -a
source "$CONFIG_EXAMPLE"
source "$CONFIG_FILE"
set +a

REMOTE="${SYNC_REMOTE_USER}@${SYNC_REMOTE_HOST}"
SSH_OPTS=(-p "$SYNC_REMOTE_PORT" -o BatchMode=yes -o ConnectTimeout=10)
RSYNC_SSH="ssh -p $SYNC_REMOTE_PORT -o BatchMode=yes -o ConnectTimeout=10"
RSYNC_ARGS=(-az --delete -e "$RSYNC_SSH")

if [[ "${SYNC_DELETE}" != "1" ]]; then
  RSYNC_ARGS=(-az -e "$RSYNC_SSH")
fi

EXCLUDES=(
  "--exclude=.dev-sync/"
  "--exclude=core/build/"
  "--exclude=core/data/"
  "--exclude=ui/frontend/node_modules/"
  "--exclude=ui/frontend/.vite/"
  "--exclude=ui/frontend/.cache/"
  "--exclude=core/config/pulsar.local.env"
)

if [[ "${SYNC_INCLUDE_GIT}" != "1" ]]; then
  EXCLUDES+=("--exclude=.git/")
fi

snapshot_tree() {
  local -a cmd=(find "$ROOT")
  if [[ "${SYNC_INCLUDE_GIT}" != "1" ]]; then
    cmd+=( -path "$ROOT/.git" -prune -o )
  fi
  cmd+=(
    -path "$ROOT/.dev-sync" -prune -o
    -path "$ROOT/core/build" -prune -o
    -path "$ROOT/core/data" -prune -o
    -path "$ROOT/ui/frontend/node_modules" -prune -o
    -path "$ROOT/ui/frontend/.vite" -prune -o
    -path "$ROOT/ui/frontend/.cache" -prune -o
    -path "$ROOT/core/config/pulsar.local.env" -prune -o
    -type f -printf '%P\t%T@\t%s\n'
  )
  "${cmd[@]}" | LC_ALL=C sort | sha256sum | awk '{print $1}'
}

ensure_remote_ready() {
  ssh "${SSH_OPTS[@]}" "$REMOTE" "mkdir -p '$SYNC_REMOTE_DIR'"
}

sync_once() {
  ensure_remote_ready
  rsync "${RSYNC_ARGS[@]}" "${EXCLUDES[@]}" "$ROOT"/ "$REMOTE:$SYNC_REMOTE_DIR"/
  log "Synced to $REMOTE:$SYNC_REMOTE_DIR"
}

main() {
  local current_state=""
  local last_state=""

  touch "$LAST_STATE_FILE"
  last_state="$(<"$LAST_STATE_FILE")"

  while true; do
    current_state="$(snapshot_tree)"
    if [[ "$current_state" != "$last_state" ]]; then
      sleep "$SYNC_DEBOUNCE_SECONDS"
      current_state="$(snapshot_tree)"
      if [[ "$current_state" != "$last_state" ]]; then
        sync_once
        printf '%s' "$current_state" >"$LAST_STATE_FILE"
        last_state="$current_state"
      fi
    fi
    sleep "$SYNC_POLL_SECONDS"
  done
}

main "$@"
