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
SSH_OPTS=(-F /dev/null -p "$SYNC_REMOTE_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10)
RSYNC_SSH="ssh -F /dev/null -p $SYNC_REMOTE_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10"
RSYNC_ARGS=(-az --delete-delay --omit-dir-times -e "$RSYNC_SSH")

if [[ "${SYNC_DELETE}" != "1" ]]; then
  RSYNC_ARGS=(-az -e "$RSYNC_SSH")
fi

EXCLUDES=(
  "--exclude=.pulsar-backups/"
  "--exclude=.dev-sync/"
  "--exclude=.codex-tmp/"
  "--exclude=core/build/"
  "--exclude=core/data/"
  "--exclude=node_modules/"
  "--exclude=ui/frontend/node_modules/"
  "--exclude=ui/frontend/dist/"
  "--exclude=ui/frontend/.vite/"
  "--exclude=ui/frontend/.cache/"
)

# Device-local configuration is preserved by default. A specific deployment
# may opt in to syncing its reviewed local configuration.
if [[ "${SYNC_INCLUDE_LOCAL_CONFIG:-0}" != "1" ]]; then
  EXCLUDES+=("--exclude=core/config/pulsar.local.env")
fi

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
  local service_q root_q user_q
  printf -v service_q '%q' "$SYNC_REMOTE_SERVICE"
  printf -v root_q '%q' "$SYNC_REMOTE_DIR"
  printf -v user_q '%q' "$SYNC_REMOTE_USER"

  printf -v remote_script 'set -Eeuo pipefail; cd %q' "$SYNC_REMOTE_DIR"
  remote_script+="; chmod +x ./run.sh ./core/scripts/*.sh"

  if [[ "${SYNC_REMOTE_BUILD_ON_SYNC:-1}" == "1" ]]; then
    if [[ "${SYNC_REMOTE_BUILD_UI_ON_SYNC:-1}" == "1" ]]; then
      remote_script+="; ./run.sh build-ui"
    fi
    remote_script+="; ./run.sh build"
    remote_script+="; LD_LIBRARY_PATH=${root_q}/camera/vendor/galaxy/lib:\${LD_LIBRARY_PATH:-} ldd ./core/build/pulsar-core | tee /tmp/pulsar-ldd.txt"
    remote_script+="; if grep -q 'not found' /tmp/pulsar-ldd.txt; then echo 'ERROR: pulsar-core has missing runtime libraries.' >&2; exit 1; fi"
  fi

  if [[ "${SYNC_REMOTE_RESTART_ON_SYNC:-1}" == "1" ]]; then
    # Normal source deploys reuse the already-installed systemd unit. Refreshing
    # a root-owned service from a script inside the writable project tree is both
    # unnecessary and unsafe. Opt in only after changing the unit definition.
    if [[ "${SYNC_REMOTE_REFRESH_SERVICE_ON_SYNC:-0}" == "1" ]]; then
      remote_script+="; sudo -n env PULSAR_RUN_USER=${user_q} ${root_q}/core/scripts/install-service.sh --refresh"
    fi
    remote_script+="; sudo -n systemctl reset-failed ${service_q} || true"
    remote_script+="; sudo -n systemctl restart ${service_q}"
    remote_script+="; ready=0"
    remote_script+="; for _ in \$(seq 1 240); do if systemctl is-active --quiet ${service_q} && curl -fsS --max-time 1 http://127.0.0.1:4173/health >/dev/null 2>&1; then ready=1; break; fi; sleep 0.5; done"
    remote_script+="; if [[ \$ready != 1 ]]; then"
    remote_script+=" echo 'ERROR: Pulsar service restarted but did not become healthy.' >&2"
    remote_script+="; echo '===== systemctl status =====' >&2; sudo -n systemctl --no-pager --full status ${service_q} >&2 || true"
    remote_script+="; echo '===== unit definition =====' >&2; sudo -n systemctl cat ${service_q} >&2 || true"
    remote_script+="; echo '===== recent journal =====' >&2; sudo -n journalctl -u ${service_q} -b --no-pager -n 180 >&2 || true"
    remote_script+="; echo '===== Pulsar log =====' >&2; tail -n 180 ${root_q}/core/data/pulsar.log >&2 || true"
    remote_script+="; echo '===== browser log =====' >&2; tail -n 80 ${root_q}/core/data/browser.log >&2 || true"
    remote_script+="; echo '===== processes/port =====' >&2; ps -ef | grep -E '[X]org|[p]ulsar-core|[c]hrome|[c]hromium' >&2 || true; ss -ltnp | grep ':4173' >&2 || true"
    remote_script+="; exit 1; fi"
    remote_script+="; echo 'Pulsar health: OK'; curl -fsS http://127.0.0.1:4173/health; echo"
    # PULSAR_REMOTE_DISPLAY_VERIFY_V1
    # HTTP health does not prove that the NVIDIA outputs have active CRTCs.
    # PULSAR_BOUNDED_REMOTE_VERIFY_V2
    remote_script+="; timeout 30 env DISPLAY=:0 ${root_q}/core/scripts/verify-displays.sh"
  fi

  ssh "${SSH_OPTS[@]}" "$REMOTE" "bash -lc $(printf '%q' "$remote_script")"
  log "Applied and verified remote build/restart on $REMOTE"
}

snapshot_tree() {
  local -a cmd=(find "$ROOT")
  if [[ "${SYNC_INCLUDE_GIT}" != "1" ]]; then
    cmd+=( -path "$ROOT/.git" -prune -o )
  fi
  cmd+=(
    -path "$ROOT/.dev-sync" -prune -o
    -path "$ROOT/.codex-tmp" -prune -o
    -path "$ROOT/.pulsar-backups" -prune -o
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
      --exclude '(^|/)(\.git|\.dev-sync|\.codex-tmp|\.pulsar-backups|node_modules|core/build|core/data|ui/frontend/node_modules|ui/frontend/dist|ui/frontend/\.vite|ui/frontend/\.cache)(/|$)|/core/config/pulsar\.local\.env$' \
      "$ROOT"
    sleep "$SYNC_DEBOUNCE_SECONDS"
    return 0
  fi

  sleep "$SYNC_POLL_SECONDS"
}

ensure_remote_ready() {
  ssh "${SSH_OPTS[@]}" "$REMOTE" "mkdir -p '$SYNC_REMOTE_DIR'"
}

backup_remote_local_config() {
  [[ "${SYNC_INCLUDE_LOCAL_CONFIG:-0}" == "1" ]] || return 0

  local local_file="$ROOT/core/config/pulsar.local.env"
  [[ -f "$local_file" ]] ||
    die "SYNC_INCLUDE_LOCAL_CONFIG=1 but $local_file does not exist."

  local stamp remote_file backup_root backup_dir
  stamp="$(date +%Y%m%d-%H%M%S)"
  remote_file="$SYNC_REMOTE_DIR/core/config/pulsar.local.env"
  backup_root="${SYNC_REMOTE_BACKUP_DIR:-/home/matin/pulsar-sync-backups}"
  backup_dir="$backup_root/local-config-$stamp"

  ssh "${SSH_OPTS[@]}" "$REMOTE"     "if [ -f $(printf '%q' "$remote_file") ]; then
       mkdir -p $(printf '%q' "$backup_dir")
       cp -a $(printf '%q' "$remote_file") $(printf '%q' "$backup_dir/")
     fi"

  log "Preserved remote pulsar.local.env in $backup_dir"
}

sync_once() {
  build_ui_if_needed
  ensure_remote_ready
  backup_remote_local_config
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
