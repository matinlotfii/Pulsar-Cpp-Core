#!/usr/bin/env bash
set -euo pipefail

run_xfixes() {
  local bin="$1"
  exec "$bin" --timeout 0 --ignore-scrolling
}

run_legacy() {
  local bin="$1"
  exec "$bin" -idle 0 -root
}

if command -v unclutter-xfixes >/dev/null 2>&1; then
  run_xfixes "$(command -v unclutter-xfixes)"
fi

if command -v unclutter >/dev/null 2>&1; then
  target="$(readlink -f "$(command -v unclutter)" 2>/dev/null || command -v unclutter)"
  case "$target" in
    *unclutter-xfixes)
      run_xfixes "$target"
      ;;
    *)
      run_legacy "$target"
      ;;
  esac
fi

exit 0
