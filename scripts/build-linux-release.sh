#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/apps/desktop"

install_deps(){
  local missing=0
  for cmd in npm cargo pkg-config rsvg-convert patchelf; do command -v "$cmd" >/dev/null 2>&1 || missing=1; done
  pkg-config --exists webkit2gtk-4.1 2>/dev/null || missing=1
  pkg-config --exists javascriptcoregtk-4.1 2>/dev/null || missing=1
  pkg-config --exists libsoup-3.0 2>/dev/null || missing=1
  ((missing==0)) && return 0
  command -v apt-get >/dev/null 2>&1 || { echo "Missing Linux build dependencies. Install Tauri 2 prerequisites for your distribution." >&2; exit 1; }
  echo "Installing Linux release build dependencies..."
  sudo apt-get update
  sudo apt-get install -y build-essential pkg-config curl wget file patchelf librsvg2-bin \
    libwebkit2gtk-4.1-dev libjavascriptcoregtk-4.1-dev libsoup-3.0-dev \
    libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev
}

install_deps
"$ROOT/scripts/prepare-tauri-icons.sh"
cd "$APP"

if [[ -f package-lock.json ]]; then npm ci; else npm install; fi
npm run build
npm run tauri build -- --bundles deb,appimage

BUNDLE="$ROOT/target/release/bundle"
if [[ ! -d "$BUNDLE" ]]; then
  BUNDLE="$APP/src-tauri/target/release/bundle"
fi

echo
echo "Linux release bundles:"
find "$BUNDLE" -maxdepth 2 -type f \( -name '*.deb' -o -name '*.AppImage' \) -print 2>/dev/null || true
