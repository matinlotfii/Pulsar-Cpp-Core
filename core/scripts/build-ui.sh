#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FRONTEND="$ROOT/ui/frontend"
DIST="$ROOT/ui/dist"
IMPORTED_DIST="$ROOT/ui/vendor/exo-ui-dist"

# PULSAR_LOCAL_NODE_BEGIN
# The server receives ui/dist built by the development laptop.
if [[ "${PULSAR_USE_PREBUILT_UI:-0}" == "1" ]]; then
  if [[ ! -f "$DIST/index.html" ]]; then
    echo "ERROR: Prebuilt Pulsar UI is missing: $DIST/index.html" >&2
    exit 1
  fi

  echo "[Pulsar] Using prebuilt UI at $DIST"
  exit 0
fi

# Local frontend build: use an already-installed modern Node.js.
pulsar_activate_local_node() {
  local major=0

  if command -v node >/dev/null 2>&1; then
    major="$(
      node -p 'parseInt(process.versions.node.split(".")[0], 10)' \
        2>/dev/null || printf '0'
    )"
  fi

  if (( major < 18 )); then
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

    if [[ -s "$NVM_DIR/nvm.sh" ]]; then
      # shellcheck disable=SC1090
      . "$NVM_DIR/nvm.sh"
      nvm use 22 >/dev/null 2>&1 || true
      hash -r
    fi
  fi

  if ! command -v node >/dev/null 2>&1; then
    echo "ERROR: Node.js روی سیستم محلی پیدا نشد." >&2
    exit 1
  fi

  major="$(
    node -p 'parseInt(process.versions.node.split(".")[0], 10)' \
      2>/dev/null || printf '0'
  )"

  if (( major < 18 )); then
    echo "ERROR: برای ساخت UI به Node.js 18 یا جدیدتر نیاز است." >&2
    echo "Active Node: $(node --version 2>/dev/null || echo unavailable)" >&2
    exit 1
  fi
}

pulsar_activate_local_node
# PULSAR_LOCAL_NODE_END


if [[ -f "$FRONTEND/package.json" && -f "$FRONTEND/vite.config.ts" ]]; then
  (
    cd "$FRONTEND"
    node_major="$(
      node -p 'parseInt(process.versions.node.split(".")[0], 10)'
    )"
    dependency_stamp="node_modules/.pulsar-node-major"
    dependencies_valid=1

    [[ -d node_modules ]] || dependencies_valid=0
    [[ -f "$dependency_stamp" ]] || dependencies_valid=0

    if [[ -f "$dependency_stamp" ]] &&
       [[ "$(cat "$dependency_stamp" 2>/dev/null || true)" != "$node_major" ]]; then
      dependencies_valid=0
    fi

    if ! node -e '
      require.resolve("typescript/package.json");
      require.resolve("vite/package.json");
    ' >/dev/null 2>&1; then
      dependencies_valid=0
    fi

    if (( dependencies_valid == 0 )); then
      echo "Installing Pulsar UI dependencies for Node.js $(node --version)..."
      rm -rf node_modules

      if [[ -f package-lock.json ]]; then
        npm ci --no-fund --no-audit
      else
        npm install --no-fund --no-audit
      fi

      printf '%s\n' "$node_major" > "$dependency_stamp"
    fi

    npm run build
  )
  rm -rf "$DIST"
  mkdir -p "$DIST"
  cp -a "$FRONTEND/dist"/. "$DIST"/
  echo "UI built from source at $FRONTEND into $DIST"
  exit 0
fi

if [[ -f "$IMPORTED_DIST/index.html" ]]; then
  rm -rf "$DIST"
  mkdir -p "$DIST"
  cp -a "$IMPORTED_DIST"/. "$DIST"/
  echo "UI imported from $IMPORTED_DIST into $DIST"
  exit 0
fi

if command -v tsc >/dev/null 2>&1; then
  tsc_cmd=(tsc)
elif command -v npx >/dev/null 2>&1; then
  tsc_cmd=(npx --yes --package typescript@5.4.5 tsc)
else
  echo "TypeScript compiler (tsc) or npx is required to rebuild the UI." >&2
  exit 1
fi
rm -rf "$DIST"
mkdir -p "$DIST/runtime"
(
  cd "$FRONTEND"
  "${tsc_cmd[@]}" -p tsconfig.json
)
cp "$FRONTEND/index.html" "$DIST/index.html"
cp "$FRONTEND/runtime/react.js" "$DIST/runtime/react.js"
cp "$FRONTEND/runtime/react-dom-client.js" "$DIST/runtime/react-dom-client.js"
{
  cat "$FRONTEND/src/styles/global.css"
  find "$FRONTEND/src/pages" -name '*.css' -type f | sort | while read -r css; do
    printf '\n/* %s */\n' "${css#"$FRONTEND/"}"
    cat "$css"
  done
  printf '\nhtml,body,button,a,input,textarea,select,*::before,*::after,*{cursor:none!important;}\n'
} > "$DIST/app.css"
echo "UI built at $DIST"
