#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG_EXAMPLE="$ROOT/core/config/dev-sync.env.example"
CONFIG_FILE="$ROOT/core/config/dev-sync.env"

log() { printf '\033[1;36m[Pulsar Sync]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[Pulsar Sync]\033[0m %s\n' "$*" >&2; exit 1; }

if [[ ! -f "$CONFIG_FILE" ]]; then
  cp "$CONFIG_EXAMPLE" "$CONFIG_FILE"
  log "Created $CONFIG_FILE. Review it if you want a different remote path."
fi

set -a
source "$CONFIG_EXAMPLE"
source "$CONFIG_FILE"
set +a

REMOTE="${SYNC_REMOTE_USER}@${SYNC_REMOTE_HOST}"
SSH_OPTS=(-p "$SYNC_REMOTE_PORT" -o BatchMode=yes -o ConnectTimeout=10)
REMOTE_URL="ssh://${SYNC_REMOTE_USER}@${SYNC_REMOTE_HOST}:${SYNC_REMOTE_PORT}${SYNC_REMOTE_GIT_DIR}"

ssh "${SSH_OPTS[@]}" "$REMOTE" "
  mkdir -p '$SYNC_REMOTE_DIR'
  mkdir -p \"\$(dirname '$SYNC_REMOTE_GIT_DIR')\"
  if [ -d '$SYNC_REMOTE_DIR/.git' ] && ! git -C '$SYNC_REMOTE_DIR' rev-parse --verify HEAD >/dev/null 2>&1; then
    rm -rf '$SYNC_REMOTE_DIR/.git'
  fi
"
ssh "${SSH_OPTS[@]}" "$REMOTE" "
  if [ ! -d '$SYNC_REMOTE_GIT_DIR' ]; then
    git init --bare -b '$SYNC_GIT_BRANCH' '$SYNC_REMOTE_GIT_DIR'
  fi
"

if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
    current_origin="$(git -C "$ROOT" remote get-url origin)"
    if [[ "$current_origin" != "$REMOTE_URL" ]]; then
      git -C "$ROOT" remote set-url origin "$REMOTE_URL"
    fi
  else
    git -C "$ROOT" remote add origin "$REMOTE_URL"
  fi
  log "Git remote is ready: $REMOTE_URL"
else
  die "Local project is not a git repository yet."
fi
