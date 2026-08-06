#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FRONTEND="$ROOT/ui/frontend"
DIST="$ROOT/ui/dist"
IMPORTED_DIST="$ROOT/ui/vendor/exo-ui-dist"

if [[ -f "$FRONTEND/package.json" && -f "$FRONTEND/vite.config.ts" ]]; then
  (
    cd "$FRONTEND"
    if [[ ! -x node_modules/.bin/vite || ! -x node_modules/.bin/tsc ]]; then
      rm -rf node_modules
      if [[ -f package-lock.json ]]; then
        npm ci --no-fund --no-audit
      else
        npm install --no-fund --no-audit
      fi
    fi
    npm run build >/dev/null
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
