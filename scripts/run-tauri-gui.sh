#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/apps/desktop"
cd "$APP"
if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required for the new desktop UI." >&2
  exit 1
fi
if [ ! -d node_modules ]; then
  npm install
fi
exec npm run tauri dev
