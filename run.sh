#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/core/scripts/common.sh"
load_config
command="${1:-start}"

needs_dependencies() {
  command -v cmake >/dev/null 2>&1 && command -v g++ >/dev/null 2>&1 && \
  command -v xinit >/dev/null 2>&1 && command -v xrandr >/dev/null 2>&1 && \
  command -v ffmpeg >/dev/null 2>&1 && find_browser >/dev/null 2>&1 && \
  ldconfig -p 2>/dev/null | grep -q 'libSDL2-2.0.so.0'
}

ui_needs_build() {
  [[ -f "$ROOT/ui/dist/index.html" ]] || return 0
  find "$ROOT/ui/frontend/src" "$ROOT/ui/frontend/runtime" \
    -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.css' -o -name '*.js' \) \
    -newer "$ROOT/ui/dist/index.html" -print -quit | grep -q .
}

case "$command" in
  start|run)
    if ! needs_dependencies; then "$ROOT/core/scripts/install-dependencies.sh"; fi
    if ui_needs_build; then "$ROOT/core/scripts/build-ui.sh"; fi
    "$ROOT/core/scripts/build-cpp.sh"
    if [[ -n "${DISPLAY:-}" ]]; then
      exec "$ROOT/core/scripts/start-session.sh"
    fi
    if [[ -d /run/systemd/system ]]; then
      if [[ ! -f /etc/systemd/system/pulsar-kiosk.service ]]; then "$ROOT/core/scripts/install-service.sh"; fi
      sudo systemctl restart pulsar-kiosk.service
      log "Pulsar started. Follow logs with: ./run.sh logs"
      exit 0
    fi
    warn "No X11 display or systemd was found; starting the API in headless mode."
    export PULSAR_HEADLESS=1
    exec "$PULSAR_BINARY" --ui-root "$ROOT/ui/dist" --data-root "$PULSAR_DATA_DIR"
    ;;
  build) "$ROOT/core/scripts/build-cpp.sh" ;;
  build-ui) "$ROOT/core/scripts/build-ui.sh" ;;
  install-deps) "$ROOT/core/scripts/install-dependencies.sh" ;;
  install-service) "$ROOT/core/scripts/install-service.sh" ;;
  sync-bootstrap) "$ROOT/core/scripts/bootstrap-sync-remote.sh" ;;
  sync-install) "$ROOT/core/scripts/install-dev-sync-service.sh" ;;
  sync-start)
    "$ROOT/core/scripts/install-dev-sync-service.sh"
    systemctl --user enable --now pulsar-dev-sync.service
    ;;
  sync-stop)
    systemctl --user disable --now pulsar-dev-sync.service || true
    ;;
  sync-status)
    systemctl --user --no-pager --full status pulsar-dev-sync.service || true
    ;;
  test|verify|smoke-test) "$ROOT/core/scripts/smoke-test.sh" ;;
  stop)
    if [[ -f /etc/systemd/system/pulsar-kiosk.service ]]; then sudo systemctl stop pulsar-kiosk.service || true; fi
    if [[ -f "$PULSAR_PID_FILE" ]]; then kill "$(cat "$PULSAR_PID_FILE")" 2>/dev/null || true; rm -f "$PULSAR_PID_FILE"; fi
    ;;
  restart) "$0" stop; exec "$0" start ;;
  status)
    [[ -x "$PULSAR_BINARY" ]] && echo "C++ build: ready" || echo "C++ build: missing"
    [[ -f "$ROOT/ui/dist/index.html" ]] && echo "UI build: ready" || echo "UI build: missing"
    curl -fsS "http://${PULSAR_HOST}:${PULSAR_PORT}/health" 2>/dev/null || echo "Core: stopped"
    ;;
  logs)
    if [[ -f /etc/systemd/system/pulsar-kiosk.service ]]; then exec journalctl -u pulsar-kiosk.service -f; fi
    exec tail -F "$PULSAR_LOG_FILE"
    ;;
  clean) rm -rf "$PULSAR_BUILD_DIR" "$PULSAR_DATA_DIR"; log "Build and runtime data removed." ;;
  *)
    cat <<USAGE
Usage: ./run.sh [start|build|build-ui|install-deps|install-service|sync-bootstrap|sync-install|sync-start|sync-stop|sync-status|test|stop|restart|status|logs|clean]
USAGE
    exit 2
    ;;
esac
