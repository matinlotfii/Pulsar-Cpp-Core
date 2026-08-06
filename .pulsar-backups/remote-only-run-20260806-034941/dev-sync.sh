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
SSH_OPTS=(-F /dev/null -p "$SYNC_REMOTE_PORT" -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10)
RSYNC_SSH="ssh -F /dev/null -p $SYNC_REMOTE_PORT -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10"
RSYNC_ARGS=(-az --delete-delay --omit-dir-times -e "$RSYNC_SSH")

if [[ "${SYNC_DELETE}" != "1" ]]; then
  RSYNC_ARGS=(-az -e "$RSYNC_SSH")
fi

EXCLUDES=(
  "--exclude=.dev-sync/"
  "--exclude=.codex-tmp/"
  "--exclude=core/build/"
  "--exclude=core/data/"
  "--exclude=node_modules/"
  "--exclude=ui/frontend/node_modules/"
  "--exclude=ui/frontend/dist/"
  "--exclude=ui/frontend/.vite/"
  "--exclude=ui/frontend/.cache/"
  "--exclude=core/config/pulsar.local.env"
)

if [[ "${SYNC_INCLUDE_GIT}" != "1" ]]; then
  EXCLUDES+=("--exclude=.git/")
fi

ui_needs_build() {
  [[ "${SYNC_BUILD_UI_LOCALLY:-1}" == "1" ]] || return 1
  [[ -f "$ROOT/ui/dist/index.html" ]] || return 0
  find "$ROOT/ui/frontend/src" "$ROOT/ui/frontend/public" "$ROOT/ui/frontend/index.html" \
    "$ROOT/ui/frontend/package.json" "$ROOT/ui/frontend/vite.config.ts" "$ROOT/ui/frontend/src/styles" \
    -type f -newer "$ROOT/ui/dist/index.html" -print -quit 2>/dev/null | grep -q .
}

build_ui_if_needed() {
  if ui_needs_build; then
    "$ROOT/core/scripts/build-ui.sh"
  fi
}

run_remote_apply() {
  local remote_script=""
  printf -v remote_script 'cd %q' "$SYNC_REMOTE_DIR"
  if [[ "${SYNC_REMOTE_BUILD_ON_SYNC:-1}" == "1" ]]; then
    remote_script+=" && RUN_REQUIRE_CUDA=${SYNC_REMOTE_REQUIRE_CUDA:-1} ./run.sh build"
  fi
  if [[ "${SYNC_REMOTE_RESTART_ON_SYNC:-1}" == "1" ]]; then
    printf -v remote_script \
      '%s && if [[ ! -f /etc/systemd/system/%q ]]; then sudo -n -E ./core/scripts/install-service.sh; fi && sudo -n systemctl restart %q' \
      "$remote_script" "$SYNC_REMOTE_SERVICE" "$SYNC_REMOTE_SERVICE"
  fi
  ssh "${SSH_OPTS[@]}" "$REMOTE" "bash -lc $(printf '%q' "$remote_script")"
  log "Applied remote build/restart on $REMOTE"
}

snapshot_tree() {
  local -a cmd=(find "$ROOT")
  if [[ "${SYNC_INCLUDE_GIT}" != "1" ]]; then
    cmd+=( -path "$ROOT/.git" -prune -o )
  fi
  cmd+=(
    -path "$ROOT/.dev-sync" -prune -o
    -path "$ROOT/.codex-tmp" -prune -o
    -path "$ROOT/core/build" -prune -o
    -path "$ROOT/core/data" -prune -o
    -path "$ROOT/node_modules" -prune -o
    -path "$ROOT/ui/frontend/node_modules" -prune -o
    -path "$ROOT/ui/frontend/dist" -prune -o
    -path "$ROOT/ui/frontend/.vite" -prune -o
    -path "$ROOT/ui/frontend/.cache" -prune -o
    -path "$ROOT/core/config/pulsar.local.env" -prune -o
    -type f -printf '%P\t%T@\t%s\n'
  )
  "${cmd[@]}" | LC_ALL=C sort | sha256sum | awk '{print $1}'
}

wait_for_change() {
  if command -v inotifywait >/dev/null 2>&1 && [[ "${SYNC_FORCE_POLLING:-0}" != "1" ]]; then
    inotifywait -qq -r \
      -e close_write,create,delete,move \
      --exclude '(^|/)(\.git|\.dev-sync|\.codex-tmp|node_modules|core/build|core/data|ui/frontend/node_modules|ui/frontend/dist|ui/frontend/\.vite|ui/frontend/\.cache)(/|$)|/core/config/pulsar\.local\.env$' \
      "$ROOT"
    sleep "$SYNC_DEBOUNCE_SECONDS"
    return 0
  fi

  sleep "$SYNC_POLL_SECONDS"
}

ensure_remote_ready() {
  ssh "${SSH_OPTS[@]}" "$REMOTE" "mkdir -p '$SYNC_REMOTE_DIR'"
}

sync_once() {
  build_ui_if_needed
  ensure_remote_ready
  rsync "${RSYNC_ARGS[@]}" "${EXCLUDES[@]}" "$ROOT"/ "$REMOTE:$SYNC_REMOTE_DIR"/
  log "Synced to $REMOTE:$SYNC_REMOTE_DIR"
  run_remote_apply
}

main() {
  local mode="${1:-}"
  local current_state=""
  local last_state=""

  if [[ "$mode" == "--once" ]]; then
    sync_once
    return 0
  fi

  touch "$LAST_STATE_FILE"
  last_state="$(<"$LAST_STATE_FILE")"

  while true; do
    wait_for_change
    current_state="$(snapshot_tree)"
    if [[ "$current_state" != "$last_state" ]]; then
      sync_once
      printf '%s' "$current_state" >"$LAST_STATE_FILE"
      last_state="$current_state"
    fi
  done
}

main "$@"
