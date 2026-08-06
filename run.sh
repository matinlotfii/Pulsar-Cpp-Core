#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/core/scripts/common.sh"
load_config
command="${1:-start}"

# Personal workstation -> GitHub -> project computer. No local CUDA/C++ build
# occurs for the default start/run command.
RUN_SYNC_REMOTE_USER="${RUN_SYNC_REMOTE_USER:-matin}"
RUN_SYNC_REMOTE_HOST="${RUN_SYNC_REMOTE_HOST:-192.168.1.123}"
RUN_SYNC_REMOTE_PORT="${RUN_SYNC_REMOTE_PORT:-22}"
RUN_SYNC_REMOTE_DIR="${RUN_SYNC_REMOTE_DIR:-/home/matin/Pulsar-Cpp-Core}"
RUN_SYNC_REMOTE_GIT_DIR="${RUN_SYNC_REMOTE_GIT_DIR:-/home/matin/git/Pulsar-Cpp-Core.git}"

RUN_GIT_REMOTE="${RUN_GIT_REMOTE:-origin}"
RUN_GIT_REMOTE_URL="${RUN_GIT_REMOTE_URL:-ssh://git@ssh.github.com:443/matinlotfii/Pulsar-Cpp-Core.git}"
RUN_GIT_SSH_COMMAND="${RUN_GIT_SSH_COMMAND:-ssh -p 443 -o HostName=ssh.github.com -o User=git -o ConnectTimeout=15 -o ConnectionAttempts=1 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new}"
RUN_GIT_BACKUP_DIR="${RUN_GIT_BACKUP_DIR:-$HOME/Downloads/Pulsar-Git-Backups}"
RUN_GIT_TAG_PREFIX="${RUN_GIT_TAG_PREFIX:-pulsar-run}"
RUN_GIT_MAX_FILE_MB="${RUN_GIT_MAX_FILE_MB:-95}"
RUN_GIT_COMMIT_MESSAGE="${RUN_GIT_COMMIT_MESSAGE:-Pulsar full-quality realtime UI-isolated deployment V8}"
RUN_GIT_PROMPT="${RUN_GIT_PROMPT:-0}"
RUN_REQUIRE_CUDA="${RUN_REQUIRE_CUDA:-1}"
# Destructive clean-replace deployment: stop the old kiosk/UI, remove the old
# remote project and its Pulsar-specific caches, then transfer this package.
RUN_REMOTE_PURGE_FIRST="${RUN_REMOTE_PURGE_FIRST:-1}"
RUN_REMOTE_PURGE_OLD_COPIES="${RUN_REMOTE_PURGE_OLD_COPIES:-1}"

on_error() {
  local code=$?
  local line="${BASH_LINENO[0]:-unknown}"
  local failed="${BASH_COMMAND:-unknown}"
  trap - ERR
  echo >&2
  echo "============================================================" >&2
  echo "PULSAR RUN FAILED" >&2
  echo "Exit code: $code" >&2
  echo "Line: $line" >&2
  echo "Command: $failed" >&2
  echo "No local application was started. Existing Git backups remain safe." >&2
  echo "If failure occurred after REMOTE CLEAN REPLACE, the old remote runtime was intentionally removed." >&2
  echo "============================================================" >&2
  exit "$code"
}
trap on_error ERR

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"
}

upsert_env() {
  local file="$1" key="$2" value="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

ensure_sync_config() {
  local example="$ROOT/core/config/dev-sync.env.example"
  local config="$ROOT/core/config/dev-sync.env"
  [[ -f "$example" ]] || die "Missing $example"
  [[ -f "$config" ]] || cp "$example" "$config"

  upsert_env "$config" SYNC_REMOTE_USER "$RUN_SYNC_REMOTE_USER"
  upsert_env "$config" SYNC_REMOTE_HOST "$RUN_SYNC_REMOTE_HOST"
  upsert_env "$config" SYNC_REMOTE_PORT "$RUN_SYNC_REMOTE_PORT"
  upsert_env "$config" SYNC_REMOTE_DIR "$RUN_SYNC_REMOTE_DIR"
  upsert_env "$config" SYNC_REMOTE_GIT_DIR "$RUN_SYNC_REMOTE_GIT_DIR"
  upsert_env "$config" SYNC_AUTO_REMOTE 1
  upsert_env "$config" SYNC_BUILD_UI_LOCALLY 0
  upsert_env "$config" SYNC_REMOTE_BUILD_UI_ON_SYNC 1
  upsert_env "$config" SYNC_REMOTE_BUILD_ON_SYNC 1
  upsert_env "$config" SYNC_REMOTE_RESTART_ON_SYNC 1
  upsert_env "$config" SYNC_REMOTE_REFRESH_SERVICE_ON_SYNC 0
  # Full-clean mode: source defaults are authoritative on every run.
  upsert_env "$config" SYNC_INCLUDE_LOCAL_CONFIG 1
}

load_sync_config() {
  ensure_sync_config
  set -a
  source "$ROOT/core/config/dev-sync.env.example"
  source "$ROOT/core/config/dev-sync.env"
  set +a
}

remote_preflight() {
  require_command ssh
  require_command rsync
  load_sync_config

  echo
  echo "========== REMOTE PREFLIGHT =========="
  local remote="${SYNC_REMOTE_USER}@${SYNC_REMOTE_HOST}"
  local check
  printf -v check 'mkdir -p %q && test -w %q && test -x /usr/local/cuda-13.2/bin/nvcc && sudo -n /usr/bin/true' \
    "$SYNC_REMOTE_DIR" "$SYNC_REMOTE_DIR"

  if ! ssh -F /dev/null -p "$SYNC_REMOTE_PORT" \
      -o BatchMode=yes -o ConnectTimeout=12 \
      -o StrictHostKeyChecking=accept-new \
      "$remote" "bash -lc $(printf '%q' "$check")"; then
    echo >&2
    echo "Remote preflight failed." >&2
    echo "Check SSH, CUDA 13.2, and the one-time limited sudo setup:" >&2
    echo "  ./run.sh setup-remote" >&2
    return 1
  fi
  log "Remote CUDA/build target is ready: $remote:$SYNC_REMOTE_DIR"
}

ensure_git_repository() {
  require_command git

  if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "Initializing Git metadata for this extracted project."
    git -C "$ROOT" init -b main
  fi

  git -C "$ROOT" config user.name >/dev/null 2>&1 || \
    git -C "$ROOT" config user.name "MatinLotfi"
  git -C "$ROOT" config user.email >/dev/null 2>&1 || \
    git -C "$ROOT" config user.email "matinlotfi.ogl@gmail.com"

  local git_dir
  git_dir="$(git -C "$ROOT" rev-parse --git-dir)"
  [[ ! -f "$git_dir/MERGE_HEAD" ]] || die "A Git merge is in progress."
  [[ ! -d "$git_dir/rebase-merge" && ! -d "$git_dir/rebase-apply" ]] || \
    die "A Git rebase is in progress."
}

ensure_github_remote() {
  if git -C "$ROOT" remote get-url "$RUN_GIT_REMOTE" >/dev/null 2>&1; then
    git -C "$ROOT" remote set-url "$RUN_GIT_REMOTE" "$RUN_GIT_REMOTE_URL"
  else
    git -C "$ROOT" remote add "$RUN_GIT_REMOTE" "$RUN_GIT_REMOTE_URL"
  fi
}

prepare_git_history() {
  ensure_git_repository
  ensure_github_remote

  echo
  echo "========== GITHUB CONNECTION =========="
  echo "Remote: $RUN_GIT_REMOTE -> $RUN_GIT_REMOTE_URL"
  GIT_SSH_COMMAND="$RUN_GIT_SSH_COMMAND" \
    git -C "$ROOT" fetch "$RUN_GIT_REMOTE" --prune --tags

  local branch
  branch="$(git -C "$ROOT" symbolic-ref --quiet --short HEAD || true)"
  [[ -n "$branch" ]] || die "Git is in detached HEAD mode."

  if ! git -C "$ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
    if git -C "$ROOT" show-ref --verify --quiet "refs/remotes/$RUN_GIT_REMOTE/$branch"; then
      # Attach an extracted ZIP to the current remote history without replacing
      # any source file in the working tree.
      git -C "$ROOT" reset --mixed "$RUN_GIT_REMOTE/$branch"
    fi
  elif git -C "$ROOT" show-ref --verify --quiet "refs/remotes/$RUN_GIT_REMOTE/$branch"; then
    git -C "$ROOT" merge-base --is-ancestor "$RUN_GIT_REMOTE/$branch" HEAD || \
      die "GitHub has commits missing locally. Re-extract the latest package or review Git history."
  fi
}

validate_staged_sizes() {
  local max_bytes=$((RUN_GIT_MAX_FILE_MB * 1024 * 1024))
  local file size
  while IFS= read -r -d '' file; do
    [[ -f "$ROOT/$file" ]] || continue
    size="$(stat -c '%s' "$ROOT/$file")"
    (( size <= max_bytes )) || die "Staged file exceeds ${RUN_GIT_MAX_FILE_MB} MiB: $file"
  done < <(git -C "$ROOT" diff --cached --name-only --diff-filter=ACMR -z)
}

checkpoint_and_push() {
  prepare_git_history

  local branch reason timestamp commit tag changed=0
  branch="$(git -C "$ROOT" symbolic-ref --quiet --short HEAD)"
  reason="$RUN_GIT_COMMIT_MESSAGE"
  if [[ "$RUN_GIT_PROMPT" == "1" && -r /dev/tty && -w /dev/tty ]]; then
    local entered=""
    read -r -p "Checkpoint message [$reason]: " entered </dev/tty || true
    [[ -z "${entered//[[:space:]]/}" ]] || reason="$entered"
  fi
  reason="${reason//$'\n'/ }"
  timestamp="$(date '+%Y%m%d-%H%M%S')"

  echo
  echo "========== STAGE PROJECT CHANGES =========="
  git -C "$ROOT" status --short
  git -C "$ROOT" add -A
  validate_staged_sizes

  if ! git -C "$ROOT" diff --cached --quiet; then
    git -C "$ROOT" commit -m "$reason [run $(date '+%Y-%m-%d %H:%M:%S %z')]" \
      -m "Remote-only Pulsar checkpoint. Build and runtime verification occur on ${RUN_SYNC_REMOTE_USER}@${RUN_SYNC_REMOTE_HOST}."
    changed=1
  else
    log "No source changes; using the current commit for deployment."
  fi

  commit="$(git -C "$ROOT" rev-parse HEAD)"
  tag="${RUN_GIT_TAG_PREFIX}-${timestamp}-${commit:0:12}"
  if git -C "$ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    tag="$tag-$RANDOM"
  fi
  git -C "$ROOT" tag -a "$tag" "$commit" -m "$reason"

  mkdir -p "$RUN_GIT_BACKUP_DIR"
  local base="$RUN_GIT_BACKUP_DIR/Pulsar-${branch}-${timestamp}-${commit:0:12}"
  echo
  echo "========== LOCAL BACKUP =========="
  git -C "$ROOT" bundle create "${base}.bundle" --all
  git -C "$ROOT" bundle verify "${base}.bundle" >/dev/null
  git -C "$ROOT" archive --format=tar.gz --prefix="Pulsar-Cpp-Core-${commit:0:12}/" \
    -o "${base}.tar.gz" "$commit"
  sha256sum "${base}.bundle" "${base}.tar.gz" >"${base}.sha256"
  log "Backup: ${base}.bundle"

  echo
  echo "========== PUSH TO GITHUB =========="
  GIT_SSH_COMMAND="$RUN_GIT_SSH_COMMAND" \
    git -C "$ROOT" push --atomic --set-upstream "$RUN_GIT_REMOTE" \
      "$branch" "refs/tags/$tag"
  log "GitHub push complete: $branch @ ${commit:0:12} (tag $tag)"
}

purge_remote_previous_deployment() {
  load_sync_config
  [[ "$RUN_REMOTE_PURGE_FIRST" == "1" ]] || {
    warn "Remote clean-replace disabled because RUN_REMOTE_PURGE_FIRST=$RUN_REMOTE_PURGE_FIRST"
    return 0
  }

  local remote="${SYNC_REMOTE_USER}@${SYNC_REMOTE_HOST}"
  local service="${SYNC_REMOTE_SERVICE:-pulsar-kiosk.service}"
  local remote_command
  printf -v remote_command 'bash -s -- %q %q %q %q' \
    "$SYNC_REMOTE_DIR" \
    "$SYNC_REMOTE_GIT_DIR" \
    "$service" \
    "$RUN_REMOTE_PURGE_OLD_COPIES"

  echo
  echo "========== REMOTE CLEAN REPLACE =========="
  log "Stopping the old Pulsar runtime/UI and removing the previous remote deployment."

  ssh -F /dev/null -p "$SYNC_REMOTE_PORT" \
    -o BatchMode=yes -o ConnectTimeout=20 \
    -o StrictHostKeyChecking=accept-new \
    "$remote" "$remote_command" <<'REMOTE'
set -Eeuo pipefail

remote_dir="$1"
remote_git_dir="$2"
service="$3"
purge_old_copies="$4"
run_user="$(id -un)"
run_uid="$(id -u)"
remote_parent="$(dirname "$remote_dir")"
remote_name="$(basename "$remote_dir")"
remote_git_name="$(basename "$remote_git_dir")"

# Destructive-operation guardrails. Refuse to run if environment variables were
# accidentally set to a broad or unrelated path.
[[ "$remote_dir" == /* && "$remote_dir" != "/" && "$remote_dir" != "$HOME" ]] || {
  echo "ERROR: unsafe remote project path: $remote_dir" >&2
  exit 1
}
[[ "$remote_name" == Pulsar-Cpp-Core* ]] || {
  echo "ERROR: refusing to purge a directory not named Pulsar-Cpp-Core*: $remote_dir" >&2
  exit 1
}
[[ "$remote_git_dir" == /* && "$remote_git_dir" != "/" && "$remote_git_dir" != "$HOME" ]] || {
  echo "ERROR: unsafe remote Git path: $remote_git_dir" >&2
  exit 1
}
[[ "$remote_git_name" == Pulsar-Cpp-Core.git ]] || {
  echo "ERROR: refusing to purge unexpected Git mirror: $remote_git_dir" >&2
  exit 1
}

printf '\n[REMOTE] Stopping old system service: %s\n' "$service"
sudo -n /usr/bin/systemctl stop "$service" 2>/dev/null || true

# Full-reset policy requested for this release: do not restore any previous
# camera, browser, display-routing or machine-local Pulsar settings. The new
# deployment starts from the package defaults and re-detects connected outputs.
rm -rf -- "$HOME/.pulsar-preserved-state"
printf '[REMOTE] Previous Pulsar settings will not be restored.\n'

# Stop and remove an old continuous-sync user service so it cannot copy stale
# files back into the freshly deployed directory.
systemctl --user disable --now pulsar-dev-sync.service >/dev/null 2>&1 || true
rm -f "$HOME/.config/systemd/user/pulsar-dev-sync.service"
systemctl --user daemon-reload >/dev/null 2>&1 || true

terminate_user_pattern() {
  local signal="$1" pattern="$2"
  pkill "-$signal" -u "$run_uid" -f -- "$pattern" 2>/dev/null || true
}

printf '[REMOTE] Terminating old Pulsar core, kiosk browser and helper processes.\n'
for pattern in \
  "$remote_dir/core/build/pulsar-core" \
  "$remote_dir/core/scripts/start-session.sh" \
  "$remote_dir/core/scripts/display-hotplug-watch.sh" \
  "$remote_dir/core/scripts/configure-displays.sh" \
  "$remote_dir/core/scripts/place-sbs-window.py" \
  "--user-data-dir=$remote_dir/core/data/browser-profile"; do
  terminate_user_pattern TERM "$pattern"
done
sleep 2
for pattern in \
  "$remote_dir/core/build/pulsar-core" \
  "$remote_dir/core/scripts/start-session.sh" \
  "$remote_dir/core/scripts/display-hotplug-watch.sh" \
  "$remote_dir/core/scripts/configure-displays.sh" \
  "$remote_dir/core/scripts/place-sbs-window.py" \
  "--user-data-dir=$remote_dir/core/data/browser-profile"; do
  terminate_user_pattern KILL "$pattern"
done

if systemctl is-active --quiet "$service" 2>/dev/null; then
  echo "ERROR: old Pulsar service is still active; refusing to delete its files." >&2
  systemctl --no-pager --full status "$service" >&2 || true
  exit 1
fi

printf '[REMOTE] Removing previous project, build tree, UI data and project Git mirror.\n'
rm -rf -- \
  "$remote_dir" \
  "${remote_dir}.new" \
  "${remote_dir}.staging" \
  "${remote_dir}.previous" \
  "$remote_git_dir"

if [[ "$purge_old_copies" == "1" && -d "$remote_parent" ]]; then
  # These directories were created by earlier rollback/deployment attempts.
  find "$remote_parent" -mindepth 1 -maxdepth 1 -type d \
    \( -name "${remote_name}.before-*" \
       -o -name "${remote_name}.old-*" \
       -o -name "${remote_name}.backup-*" \
       -o -name "${remote_name}.staging-*" \) \
    -exec rm -rf -- {} + 2>/dev/null || true
fi

printf '[REMOTE] Removing Pulsar-specific user caches and temporary runtime data.\n'
rm -rf -- \
  "$HOME/.cache/pulsar" \
  "$HOME/.cache/Pulsar" \
  "$HOME/.config/pulsar" \
  "$HOME/.local/state/pulsar" \
  "$HOME/.local/share/pulsar" \
  "$HOME/.dev-sync" \
  "$HOME/.pulsar-preserved-state" \
  "$HOME/pulsar-diagnostics" \
  "/tmp/pulsar-runtime-$run_user" 2>/dev/null || true

# Remove only temporary Pulsar entries owned by this user; do not touch other
# users' files or unrelated system caches.
find /tmp -mindepth 1 -maxdepth 1 -uid "$run_uid" \
  \( -name 'pulsar-*' -o -name '.pulsar-*' \) \
  -exec rm -rf -- {} + 2>/dev/null || true

mkdir -p "$remote_dir"
chmod 0755 "$remote_dir"
test -d "$remote_dir" -a -w "$remote_dir"

printf '[REMOTE] Clean destination ready: %s\n' "$remote_dir"
REMOTE
}

collect_remote_diagnostics() {
  load_sync_config
  local remote="${SYNC_REMOTE_USER}@${SYNC_REMOTE_HOST}"
  local local_dir="$ROOT/diagnostics"
  mkdir -p "$local_dir"

  echo
  echo "========== LOW-OVERHEAD SYSTEM TRACE =========="
  local output archive summary
  output="$(ssh -F /dev/null -p "$SYNC_REMOTE_PORT" \
    -o BatchMode=yes -o ConnectTimeout=20 \
    -o StrictHostKeyChecking=accept-new \
    "$remote" "cd $(printf '%q' "$SYNC_REMOTE_DIR") && source ./core/config/pulsar.env && ./core/scripts/collect-systemwide-trace.sh \"\${PULSAR_SYSTEM_TRACE_SECONDS:-30}\"")" || {
      warn "Automatic diagnostic collection failed; deployment remains active."
      return 0
    }
  printf '%s\n' "$output"
  archive="$(printf '%s\n' "$output" | sed -n 's/^ARCHIVE=//p' | tail -n1)"
  summary="$(printf '%s\n' "$output" | sed -n 's/^SUMMARY=//p' | tail -n1)"
  if [[ -n "$archive" ]]; then
    scp -F /dev/null -P "$SYNC_REMOTE_PORT" -q \
      -o StrictHostKeyChecking=accept-new "$remote:$archive" "$local_dir/"
  fi
  if [[ -n "$summary" ]]; then
    scp -F /dev/null -P "$SYNC_REMOTE_PORT" -q \
      -o StrictHostKeyChecking=accept-new "$remote:$summary" "$local_dir/"
  fi
  log "Systemwide diagnostic files saved locally: $local_dir"
}

deploy_remote() {
  load_sync_config
  "$ROOT/core/scripts/dev-sync.sh" --once
  log "Remote build, camera verification and service restart completed."
}

setup_remote_sudo() {
  load_sync_config
  local remote="${SYNC_REMOTE_USER}@${SYNC_REMOTE_HOST}"
  ssh -t -F /dev/null -p "$SYNC_REMOTE_PORT" \
    -o StrictHostKeyChecking=accept-new "$remote" 'bash -s' <<'REMOTE'
set -e
rule='matin ALL=(root) NOPASSWD: /usr/bin/true, /usr/bin/systemctl reset-failed pulsar-kiosk.service, /usr/bin/systemctl restart pulsar-kiosk.service, /usr/bin/systemctl start pulsar-kiosk.service, /usr/bin/systemctl stop pulsar-kiosk.service, /usr/bin/systemctl daemon-reload'
printf '%s\n' "$rule" | sudo tee /etc/sudoers.d/pulsar-kiosk >/dev/null
sudo chmod 0440 /etc/sudoers.d/pulsar-kiosk
sudo visudo -cf /etc/sudoers.d/pulsar-kiosk
sudo -n /usr/bin/true
echo 'Remote limited sudo is ready.'
REMOTE
}

case "$command" in
  start|run)
    echo
    echo "========== REMOTE-ONLY DEPLOYMENT =========="
    log "This computer only commits, pushes and transfers source; CUDA build runs on pulsar."
    remote_preflight
    checkpoint_and_push
    purge_remote_previous_deployment
    deploy_remote
    collect_remote_diagnostics
    ;;
  setup-remote)
    setup_remote_sudo
    ;;
  purge-remote)
    remote_preflight
    purge_remote_previous_deployment
    ;;
  backup|checkpoint)
    checkpoint_and_push
    ;;
  build)
    PULSAR_REQUIRE_CUDA="$RUN_REQUIRE_CUDA" "$ROOT/core/scripts/build-cpp.sh"
    ;;
  build-ui)
    "$ROOT/core/scripts/build-ui.sh"
    ;;
  install-deps)
    "$ROOT/core/scripts/install-dependencies.sh"
    ;;
  install-service)
    "$ROOT/core/scripts/install-service.sh"
    ;;
  test|verify|smoke-test)
    "$ROOT/core/scripts/smoke-test.sh"
    ;;
  status)
    [[ -x "$PULSAR_BINARY" ]] && echo "C++ build: ready" || echo "C++ build: missing"
    [[ -f "$ROOT/ui/dist/index.html" ]] && echo "UI build: ready" || echo "UI build: missing"
    curl -fsS "http://${PULSAR_HOST}:${PULSAR_PORT}/health" 2>/dev/null || echo "Core: stopped"
    ;;
  logs)
    if [[ -d /run/systemd/system ]]; then
      exec journalctl -u pulsar-kiosk.service -f
    fi
    exec tail -F "$PULSAR_LOG_FILE"
    ;;
  clean)
    rm -rf "$PULSAR_BUILD_DIR" "$PULSAR_DATA_DIR"
    ;;
  *)
    cat <<'USAGE'
Usage:
  ./run.sh                 Commit/push, purge old remote runtime/project, sync, build, restart
  ./run.sh setup-remote    One-time limited sudo setup on the project computer
  ./run.sh purge-remote    Stop/delete the previous remote project and Pulsar caches
  ./run.sh backup          Commit/push without deployment
  ./run.sh build           Build C++/CUDA on the current computer
  ./run.sh build-ui        Build UI on the current computer
  ./run.sh status
  ./run.sh logs
  ./run.sh clean
USAGE
    exit 2
    ;;
esac
