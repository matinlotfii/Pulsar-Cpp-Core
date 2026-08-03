#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
USER_NAME="${PULSAR_RUN_USER:-${SUDO_USER:-root}}"
export DISPLAY="${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="/tmp/pulsar-runtime-$USER_NAME"
mkdir -p "$XDG_RUNTIME_DIR"
if [[ "$USER_NAME" != "root" ]]; then
  chown "$USER_NAME":"$(id -gn "$USER_NAME")" "$XDG_RUNTIME_DIR"
fi
chmod 700 "$XDG_RUNTIME_DIR"
xhost +SI:localuser:"$USER_NAME" >/dev/null 2>&1 || true

if [[ "$USER_NAME" == "root" ]]; then
  if command -v dbus-run-session >/dev/null 2>&1; then
    exec dbus-run-session -- "$ROOT/core/scripts/start-session.sh"
  fi
  exec "$ROOT/core/scripts/start-session.sh"
fi
user_home="$(getent passwd "$USER_NAME" | cut -d: -f6)"
session_command=("$ROOT/core/scripts/start-session.sh")
if command -v dbus-run-session >/dev/null 2>&1; then
  session_command=(dbus-run-session -- "${session_command[@]}")
fi
exec runuser -u "$USER_NAME" -- env \
  DISPLAY="$DISPLAY" \
  XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
  HOME="$user_home" USER="$USER_NAME" LOGNAME="$USER_NAME" \
  "${session_command[@]}"
