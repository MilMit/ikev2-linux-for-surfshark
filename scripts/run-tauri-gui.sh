#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/apps/desktop"
cd "$APP"

if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required for the new desktop UI." >&2
  exit 1
fi

# Tauri on Linux needs WebKitGTK/libsoup development packages at build time.
missing_pkgs=()
for pkg in libwebkit2gtk-4.1-dev libsoup-3.0-dev libjavascriptcoregtk-4.1-dev; do
  if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
    missing_pkgs+=("$pkg")
  fi
done

if ((${#missing_pkgs[@]})); then
  echo "Installing required Tauri Linux build dependencies: ${missing_pkgs[*]}"
  sudo apt-get update
  sudo apt-get install -y "${missing_pkgs[@]}"
fi

if [ ! -d node_modules ]; then
  npm install
fi

exec npm run tauri dev
