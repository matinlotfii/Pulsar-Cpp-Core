#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FRONTEND="$ROOT/ui/frontend"
DIST="$ROOT/ui/dist"
command -v tsc >/dev/null 2>&1 || { echo "TypeScript compiler (tsc) is required to rebuild the UI." >&2; exit 1; }
rm -rf "$DIST"
mkdir -p "$DIST/runtime"
(
  cd "$FRONTEND"
  tsc -p tsconfig.json
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
} > "$DIST/app.css"
echo "UI built at $DIST"
