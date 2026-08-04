#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# Pulsar professional runner
#
# Default ./run.sh workflow:
#   1) Ask why this run is being made.
#   2) Stage every non-ignored project change.
#   3) Create a timestamped Git commit on every run, even with no file changes.
#   4) Create an annotated backup tag.
#   5) Create verified local Git bundle + source archive backups.
#   6) Push the branch and this run's tag atomically to GitHub over SSH port 443.
#   7) Only after a successful GitHub push, sync/start Pulsar on 192.168.1.123.
#
# The GitHub repository and the Pulsar runtime device are intentionally separate.
# =============================================================================

# -----------------------------------------------------------------------------
# Pulsar runtime/sync target
# -----------------------------------------------------------------------------
RUN_SYNC_REMOTE_USER="${RUN_SYNC_REMOTE_USER:-matin}"
RUN_SYNC_REMOTE_HOST="${RUN_SYNC_REMOTE_HOST:-192.168.1.123}"
RUN_SYNC_REMOTE_PORT="${RUN_SYNC_REMOTE_PORT:-22}"
RUN_SYNC_REMOTE_DIR="${RUN_SYNC_REMOTE_DIR:-/home/matin/Pulsar-Cpp-Core}"
RUN_SYNC_REMOTE_GIT_DIR="${RUN_SYNC_REMOTE_GIT_DIR:-/home/matin/git/Pulsar-Cpp-Core.git}"

# -----------------------------------------------------------------------------
# GitHub backup target
# Uses GitHub's SSH endpoint on port 443, suitable when outbound SSH port 22
# is blocked by the network.
# -----------------------------------------------------------------------------
RUN_GIT_REMOTE="${RUN_GIT_REMOTE:-origin}"
RUN_GIT_REMOTE_URL="${RUN_GIT_REMOTE_URL:-ssh://git@ssh.github.com:443/matinlotfii/Pulsar-Cpp-Core.git}"
RUN_GIT_SSH_COMMAND="${RUN_GIT_SSH_COMMAND:-ssh -p 443 -o HostName=ssh.github.com -o User=git -o ConnectTimeout=12 -o ConnectionAttempts=1 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=accept-new}"

# Local, restorable backup storage on this computer.
RUN_GIT_BACKUP_DIR="${RUN_GIT_BACKUP_DIR:-$HOME/Downloads/Pulsar-Git-Backups}"
RUN_GIT_TAG_PREFIX="${RUN_GIT_TAG_PREFIX:-pulsar-run}"
RUN_GIT_MAX_FILE_MB="${RUN_GIT_MAX_FILE_MB:-95}"

# Optional non-interactive commit reason:
#   RUN_GIT_COMMIT_MESSAGE="Reason" ./run.sh
RUN_GIT_COMMIT_MESSAGE="${RUN_GIT_COMMIT_MESSAGE:-}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/core/scripts/common.sh"
load_config
command="${1:-start}"

on_error() {
  local exit_code=$?
  local line_number="${BASH_LINENO[0]:-unknown}"
  local failed_command="${BASH_COMMAND:-unknown}"

  # Prevent the handler itself from retriggering.
  trap - ERR

  echo >&2
  echo "============================================================" >&2
  echo "PULSAR RUN FAILED" >&2
  echo "Exit code: $exit_code" >&2
  echo "Line: $line_number" >&2
  echo "Command: $failed_command" >&2
  echo "GitHub push or Pulsar sync/start did not complete." >&2
  echo "Any local Git commit and backup already created remain safe." >&2
  echo "============================================================" >&2
  exit "$exit_code"
}
trap on_error ERR

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Required command is missing: $1" >&2
    return 1
  }
}

upsert_sync_config_value() {
  local file="$1" key="$2" value="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

ensure_run_sync_target() {
  local example="$ROOT/core/config/dev-sync.env.example"
  local config="$ROOT/core/config/dev-sync.env"

  [[ -f "$example" ]] || return 1
  [[ -f "$config" ]] || cp "$example" "$config"

  upsert_sync_config_value "$config" "SYNC_REMOTE_USER" "$RUN_SYNC_REMOTE_USER"
  upsert_sync_config_value "$config" "SYNC_REMOTE_HOST" "$RUN_SYNC_REMOTE_HOST"
  upsert_sync_config_value "$config" "SYNC_REMOTE_PORT" "$RUN_SYNC_REMOTE_PORT"
  upsert_sync_config_value "$config" "SYNC_REMOTE_DIR" "$RUN_SYNC_REMOTE_DIR"
  upsert_sync_config_value "$config" "SYNC_REMOTE_GIT_DIR" "$RUN_SYNC_REMOTE_GIT_DIR"
}

load_sync_config() {
  local example="$ROOT/core/config/dev-sync.env.example"
  local config="$ROOT/core/config/dev-sync.env"

  [[ -f "$example" ]] || return 1
  ensure_run_sync_target

  set -a
  source "$example"
  [[ -f "$config" ]] && source "$config"
  set +a
}

remote_start_requested() {
  load_sync_config || return 1
  [[ "${SYNC_AUTO_REMOTE:-0}" == "1" ]] || return 1
  [[ "${SYNC_REMOTE_DIR:-}" != "$ROOT" ]]
}

needs_dependencies() {
  command -v cmake >/dev/null 2>&1 &&
    command -v g++ >/dev/null 2>&1 &&
    command -v xinit >/dev/null 2>&1 &&
    command -v xrandr >/dev/null 2>&1 &&
    command -v ffmpeg >/dev/null 2>&1 &&
    find_browser >/dev/null 2>&1 &&
    ldconfig -p 2>/dev/null | grep -q 'libSDL2-2.0.so.0'
}

ui_needs_build() {
  [[ -f "$ROOT/ui/dist/index.html" ]] || return 0

  local -a search_paths=("$ROOT/ui/frontend/src")
  [[ -d "$ROOT/ui/frontend/runtime" ]] &&
    search_paths+=("$ROOT/ui/frontend/runtime")

  find "${search_paths[@]}" \
    -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.css' -o -name '*.js' \) \
    -newer "$ROOT/ui/dist/index.html" -print -quit |
    grep -q .
}

ensure_git_repository() {
  require_command git

  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "ERROR: $ROOT is not a Git working tree." >&2
    return 1
  }

  local git_dir
  git_dir="$(git -C "$ROOT" rev-parse --git-dir)"

  [[ ! -f "$git_dir/MERGE_HEAD" ]] || {
    echo "ERROR: A Git merge is currently in progress." >&2
    echo "Finish or abort the merge before running Pulsar." >&2
    return 1
  }

  [[ ! -d "$git_dir/rebase-merge" && ! -d "$git_dir/rebase-apply" ]] || {
    echo "ERROR: A Git rebase is currently in progress." >&2
    echo "Finish or abort the rebase before running Pulsar." >&2
    return 1
  }

  git -C "$ROOT" config user.name >/dev/null || {
    echo 'ERROR: Configure Git name first:' >&2
    echo '  git config --global user.name "MatinLotfi"' >&2
    return 1
  }

  git -C "$ROOT" config user.email >/dev/null || {
    echo 'ERROR: Configure Git email first:' >&2
    echo '  git config --global user.email "matinlotfi.ogl@gmail.com"' >&2
    return 1
  }
}

ensure_github_remote() {
  local current_url=""

  if git -C "$ROOT" remote get-url "$RUN_GIT_REMOTE" >/dev/null 2>&1; then
    current_url="$(git -C "$ROOT" remote get-url "$RUN_GIT_REMOTE")"
    if [[ "$current_url" != "$RUN_GIT_REMOTE_URL" ]]; then
      log "Updating GitHub remote '$RUN_GIT_REMOTE':"
      log "  old: $current_url"
      log "  new: $RUN_GIT_REMOTE_URL"
      git -C "$ROOT" remote set-url "$RUN_GIT_REMOTE" "$RUN_GIT_REMOTE_URL"
    fi
  else
    log "Creating GitHub remote '$RUN_GIT_REMOTE': $RUN_GIT_REMOTE_URL"
    git -C "$ROOT" remote add "$RUN_GIT_REMOTE" "$RUN_GIT_REMOTE_URL"
  fi
}

get_current_branch() {
  git -C "$ROOT" symbolic-ref --quiet --short HEAD || {
    echo "ERROR: Git is in detached HEAD mode." >&2
    echo "Checkout a branch, for example: git switch main" >&2
    return 1
  }
}

RUN_REASON_RESULT=""
RUN_COMMIT_HASH_RESULT=""
RUN_TAG_NAME_RESULT=""

ask_run_reason() {
  local reason="$RUN_GIT_COMMIT_MESSAGE"

  echo
  echo "========== RUN REASON =========="

  if [[ -z "$reason" ]]; then
    if [[ -r /dev/tty && -w /dev/tty ]]; then
      while [[ -z "${reason//[[:space:]]/}" ]]; do
        read -r -p "Why are you running Pulsar? Commit message: " reason </dev/tty

        if [[ -z "${reason//[[:space:]]/}" ]]; then
          echo "Commit message cannot be empty."
        fi
      done
    else
      echo "ERROR: A commit message is required." >&2
      echo 'Use: RUN_GIT_COMMIT_MESSAGE="Reason for this run" ./run.sh' >&2
      return 1
    fi
  fi

  # Keep the subject line readable and prevent embedded newlines.
  reason="${reason//$'\r'/ }"
  reason="${reason//$'\n'/ }"

  RUN_REASON_RESULT="$reason"
}

validate_staged_file_sizes() {
  local max_bytes=$((RUN_GIT_MAX_FILE_MB * 1024 * 1024))
  local file size
  local -a oversized=()

  while IFS= read -r -d '' file; do
    [[ -f "$ROOT/$file" ]] || continue
    size="$(stat -c '%s' "$ROOT/$file")"
    if ((size > max_bytes)); then
      oversized+=("$file ($size bytes)")
    fi
  done < <(
    git -C "$ROOT" diff --cached \
      --name-only --diff-filter=ACMR -z
  )

  if ((${#oversized[@]} > 0)); then
    echo >&2
    echo "ERROR: These staged files exceed ${RUN_GIT_MAX_FILE_MB} MiB:" >&2
    printf '  - %s\n' "${oversized[@]}" >&2
    echo "Add them to .gitignore or configure Git LFS, then run again." >&2
    return 1
  fi
}

fetch_and_validate_github() {
  local branch="$1"

  echo
  echo "========== GITHUB CONNECTION =========="
  echo "Remote: $RUN_GIT_REMOTE -> $RUN_GIT_REMOTE_URL"

  GIT_SSH_COMMAND="$RUN_GIT_SSH_COMMAND" \
    git -C "$ROOT" fetch "$RUN_GIT_REMOTE" --prune

  if git -C "$ROOT" show-ref --verify --quiet \
      "refs/remotes/$RUN_GIT_REMOTE/$branch"; then

    if ! git -C "$ROOT" merge-base --is-ancestor \
        "$RUN_GIT_REMOTE/$branch" HEAD; then
      echo "ERROR: GitHub contains commits that are missing locally." >&2
      echo "To avoid overwriting history, this run was stopped." >&2
      echo "Review first with:" >&2
      echo "  git log --oneline --graph --decorate --all" >&2
      return 1
    fi
  fi
}

create_run_commit_and_tag() {
  local reason="$1"
  local timestamp_compact="$2"
  local timestamp_display="$3"
  local branch="$4"

  echo

# PULSAR_LOCAL_UI_BUILD_BEGIN
# Source changes are built locally before Git staging and deployment.
# Remote builds receive PULSAR_USE_PREBUILT_UI=1 and skip frontend compilation.
if [[ "${PULSAR_USE_PREBUILT_UI:-0}" != "1" ]]; then
  echo
  echo "========== LOCAL UI BUILD =========="
  "$ROOT/core/scripts/build-ui.sh"
fi
# PULSAR_LOCAL_UI_BUILD_END

  echo "========== STAGE PROJECT CHANGES =========="
  git -C "$ROOT" status --short
  git -C "$ROOT" add -A
  validate_staged_file_sizes

  local change_summary
  if git -C "$ROOT" diff --cached --quiet; then
    change_summary="No source-file changes; this is a run checkpoint."
  else
    change_summary="$(
      git -C "$ROOT" diff --cached --stat |
        tail -n 1 |
        sed 's/^[[:space:]]*//'
    )"
  fi

  local subject full_body
  subject="$reason [run $timestamp_display]"
  full_body="$(
    cat <<EOF
Automatic Pulsar run checkpoint.

Reason: $reason
Timestamp: $timestamp_display
Computer: $(hostname)
User: $(id -un)
Branch: $branch
Changes: $change_summary
GitHub: $RUN_GIT_REMOTE_URL
Pulsar device: ${RUN_SYNC_REMOTE_USER}@${RUN_SYNC_REMOTE_HOST}:${RUN_SYNC_REMOTE_DIR}
EOF
  )"

  echo
  echo "========== CREATE COMMIT =========="
  git -C "$ROOT" commit --allow-empty \
    -m "$subject" \
    -m "$full_body"

  local commit_hash tag_name
  commit_hash="$(git -C "$ROOT" rev-parse HEAD)"
  tag_name="${RUN_GIT_TAG_PREFIX}-${timestamp_compact}-${commit_hash:0:12}"

  if git -C "$ROOT" rev-parse -q --verify \
      "refs/tags/$tag_name" >/dev/null; then
    tag_name="${tag_name}-$RANDOM"
  fi

  git -C "$ROOT" tag -a "$tag_name" "$commit_hash" \
    -m "$reason" \
    -m "Pulsar run checkpoint created at $timestamp_display"

  RUN_COMMIT_HASH_RESULT="$commit_hash"
  RUN_TAG_NAME_RESULT="$tag_name"

  log "Created commit: ${commit_hash:0:12}"
  log "Created backup tag: $tag_name"
}

create_local_backups() {
  local timestamp_compact="$1"
  local branch="$2"
  local commit_hash="$3"
  local tag_name="$4"
  local reason="$5"

  require_command tar
  require_command sha256sum

  mkdir -p "$RUN_GIT_BACKUP_DIR"

  local safe_branch backup_base bundle archive metadata checksums
  safe_branch="${branch//\//-}"
  backup_base="$RUN_GIT_BACKUP_DIR/Pulsar-${safe_branch}-${timestamp_compact}-${commit_hash:0:12}"
  bundle="${backup_base}.bundle"
  archive="${backup_base}.tar.gz"
  metadata="${backup_base}.info.txt"
  checksums="${backup_base}.sha256"

  echo
  echo "========== LOCAL BACKUP =========="

  # Full Git history, branches and tags.
  git -C "$ROOT" bundle create "$bundle" --all
  git -C "$ROOT" bundle verify "$bundle" >/dev/null

  # Easy-to-extract source snapshot of the exact committed state.
  git -C "$ROOT" archive \
    --format=tar.gz \
    --prefix="Pulsar-Cpp-Core-${commit_hash:0:12}/" \
    -o "$archive" \
    "$commit_hash"

  {
    printf 'Project: Pulsar-Cpp-Core\n'
    printf 'Reason: %s\n' "$reason"
    printf 'Created: %s\n' "$(date --iso-8601=seconds)"
    printf 'Branch: %s\n' "$branch"
    printf 'Commit: %s\n' "$commit_hash"
    printf 'Tag: %s\n' "$tag_name"
    printf 'GitHub: %s\n' "$RUN_GIT_REMOTE_URL"
    printf 'Pulsar device: %s@%s:%s\n' \
      "$RUN_SYNC_REMOTE_USER" "$RUN_SYNC_REMOTE_HOST" "$RUN_SYNC_REMOTE_DIR"
    printf 'Git bundle: %s\n' "$bundle"
    printf 'Source archive: %s\n' "$archive"
  } >"$metadata"

  sha256sum "$bundle" "$archive" "$metadata" >"$checksums"

  log "Git bundle: $bundle"
  log "Source archive: $archive"
  log "Checksums: $checksums"
}

push_run_to_github() {
  local branch="$1"
  local tag_name="$2"

  echo
  echo "========== PUSH TO GITHUB =========="

  # Branch and this run's tag either both arrive or neither arrives.
  GIT_SSH_COMMAND="$RUN_GIT_SSH_COMMAND" \
    git -C "$ROOT" push --atomic \
      --set-upstream "$RUN_GIT_REMOTE" \
      "$branch" \
      "refs/tags/$tag_name"

  log "GitHub backup completed."
  log "Branch: $RUN_GIT_REMOTE/$branch"
  log "Tag: $tag_name"
}

professional_git_checkpoint() {
  ensure_git_repository
  ensure_github_remote

  local branch reason timestamp_compact timestamp_display
  local commit_hash tag_name

  branch="$(get_current_branch)"

  ask_run_reason
  reason="$RUN_REASON_RESULT"

  timestamp_compact="$(date '+%Y%m%d-%H%M%S')"
  timestamp_display="$(date '+%Y-%m-%d %H:%M:%S %z')"

  fetch_and_validate_github "$branch"

  create_run_commit_and_tag \
    "$reason" \
    "$timestamp_compact" \
    "$timestamp_display" \
    "$branch"

  commit_hash="$RUN_COMMIT_HASH_RESULT"
  tag_name="$RUN_TAG_NAME_RESULT"

  create_local_backups \
    "$timestamp_compact" \
    "$branch" \
    "$commit_hash" \
    "$tag_name" \
    "$reason"

  push_run_to_github "$branch" "$tag_name"

  echo
  echo "========== CHECKPOINT COMPLETE =========="
  git -C "$ROOT" log -1 \
    --date=iso-local \
    --format='Commit: %H%nDate: %ad%nMessage: %s'
  echo "Tag: $tag_name"
}

run_remote_pulsar() {
  # One-shot sync is deliberate. The always-running dev-sync service is not
  # automatically enabled here, because every controlled ./run.sh must create
  # a GitHub checkpoint before files are sent to the Pulsar device.
  "$ROOT/core/scripts/dev-sync.sh" --once
  log "Pulsar synced and started on ${SYNC_REMOTE_USER}@${SYNC_REMOTE_HOST}:${SYNC_REMOTE_DIR}"
}

list_local_backups() {
  mkdir -p "$RUN_GIT_BACKUP_DIR"
  echo "Backup directory: $RUN_GIT_BACKUP_DIR"
  find "$RUN_GIT_BACKUP_DIR" \
    -maxdepth 1 \
    -type f \
    -printf '%TY-%Tm-%Td %TH:%TM:%TS | %f | %s bytes\n' |
    sort -r
}

case "$command" in
  start|run)
    professional_git_checkpoint

    if remote_start_requested; then
      run_remote_pulsar
      exit 0
    fi

    if ! needs_dependencies; then
      "$ROOT/core/scripts/install-dependencies.sh"
    fi

    if ui_needs_build; then
      "$ROOT/core/scripts/build-ui.sh"
    fi

    "$ROOT/core/scripts/build-cpp.sh"

    if [[ -n "${DISPLAY:-}" ]]; then
      exec "$ROOT/core/scripts/start-session.sh"
    fi

    if [[ -d /run/systemd/system ]]; then
      if [[ ! -f /etc/systemd/system/pulsar-kiosk.service ]]; then
        "$ROOT/core/scripts/install-service.sh"
      fi
      sudo systemctl restart pulsar-kiosk.service
      log "Pulsar started. Follow logs with: ./run.sh logs"
      exit 0
    fi

    warn "No X11 display or systemd was found; starting the API in headless mode."
    export PULSAR_HEADLESS=1
    exec "$PULSAR_BINARY" \
      --ui-root "$ROOT/ui/dist" \
      --data-root "$PULSAR_DATA_DIR"
    ;;

  backup|git-backup|checkpoint)
    professional_git_checkpoint
    ;;

  backups|list-backups)
    list_local_backups
    ;;

  build)
    "$ROOT/core/scripts/build-cpp.sh"
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

  sync-bootstrap)
    "$ROOT/core/scripts/bootstrap-sync-remote.sh"
    ;;

  sync-install)
    "$ROOT/core/scripts/install-dev-sync-service.sh"
    ;;

  sync-start)
    echo "WARNING: Continuous sync can copy changes without a GitHub checkpoint."
    "$ROOT/core/scripts/install-dev-sync-service.sh"
    systemctl --user enable --now pulsar-dev-sync.service
    ;;

  sync-stop)
    systemctl --user disable --now pulsar-dev-sync.service || true
    ;;

  sync-status)
    systemctl --user --no-pager --full \
      status pulsar-dev-sync.service || true
    ;;

  test|verify|smoke-test)
    "$ROOT/core/scripts/smoke-test.sh"
    ;;

  stop)
    if [[ -f /etc/systemd/system/pulsar-kiosk.service ]]; then
      sudo systemctl stop pulsar-kiosk.service || true
    fi

    if [[ -f "$PULSAR_PID_FILE" ]]; then
      kill "$(cat "$PULSAR_PID_FILE")" 2>/dev/null || true
      rm -f "$PULSAR_PID_FILE"
    fi
    ;;

  restart)
    "$0" stop
    exec "$0" start
    ;;

  status)
    [[ -x "$PULSAR_BINARY" ]] &&
      echo "C++ build: ready" ||
      echo "C++ build: missing"

    [[ -f "$ROOT/ui/dist/index.html" ]] &&
      echo "UI build: ready" ||
      echo "UI build: missing"

    curl -fsS "http://${PULSAR_HOST}:${PULSAR_PORT}/health" 2>/dev/null ||
      echo "Core: stopped"
    ;;

  logs)
    if [[ -f /etc/systemd/system/pulsar-kiosk.service ]]; then
      exec journalctl -u pulsar-kiosk.service -f
    fi
    exec tail -F "$PULSAR_LOG_FILE"
    ;;

  clean)
    rm -rf "$PULSAR_BUILD_DIR" "$PULSAR_DATA_DIR"
    log "Build and runtime data removed."
    ;;

  *)
    cat <<'USAGE'
Usage:
  ./run.sh
  ./run.sh start
  ./run.sh backup
  ./run.sh backups
  ./run.sh build
  ./run.sh build-ui
  ./run.sh install-deps
  ./run.sh install-service
  ./run.sh sync-bootstrap
  ./run.sh sync-install
  ./run.sh sync-start
  ./run.sh sync-stop
  ./run.sh sync-status
  ./run.sh test
  ./run.sh stop
  ./run.sh restart
  ./run.sh status
  ./run.sh logs
  ./run.sh clean

Default ./run.sh:
  Ask for the run reason
  -> create a timestamped commit, even with no changed files
  -> create a timestamped annotated tag
  -> create verified local bundle/source backups
  -> atomically push branch + tag to GitHub over port 443
  -> sync and start Pulsar on 192.168.1.123
USAGE
    exit 2
    ;;
esac
