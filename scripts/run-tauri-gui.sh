#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/apps/desktop"
TAURI_DIR="$APP/src-tauri"
cd "$APP"

if ! command -v npm >/dev/null 2>&1; then echo "npm is required for the new desktop UI." >&2; exit 1; fi
if ! command -v pkg-config >/dev/null 2>&1; then sudo apt-get update; sudo apt-get install -y pkg-config; fi
need_install=0
for module in webkit2gtk-4.1 libsoup-3.0 javascriptcoregtk-4.1; do pkg-config --exists "$module" || need_install=1; done
if ((need_install)); then
  echo "Installing/repairing required Tauri Linux build dependencies..."
  sudo apt-get update
  sudo apt-get install -y build-essential pkg-config libwebkit2gtk-4.1-dev libjavascriptcoregtk-4.1-dev libsoup-3.0-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev
fi
MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
pc_paths=("/usr/lib/pkgconfig" "/usr/share/pkgconfig"); [[ -n "$MULTIARCH" ]] && pc_paths=("/usr/lib/$MULTIARCH/pkgconfig" "${pc_paths[@]}")
for p in "${pc_paths[@]}"; do [[ -d "$p" ]] || continue; case ":${PKG_CONFIG_PATH:-}:" in *":$p:"*) ;; *) export PKG_CONFIG_PATH="$p${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" ;; esac; done
missing_modules=(); for module in webkit2gtk-4.1 libsoup-3.0 javascriptcoregtk-4.1; do pkg-config --exists "$module" || missing_modules+=("$module"); done
if ((${#missing_modules[@]})); then echo "ERROR: pkg-config still cannot find: ${missing_modules[*]}" >&2; echo "PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-<unset>}" >&2; exit 1; fi
echo "Tauri native dependencies detected:"; pkg-config --modversion webkit2gtk-4.1 libsoup-3.0 javascriptcoregtk-4.1

# Keep the root-owned helper/backend synchronized with the checkout. This is
# needed when a UI feature introduces a new fixed helper action. Use bash as
# the pkexec target so the installer does not need its executable bit set in
# the checkout (which can otherwise surface as a misleading auth failure).
SOURCE_HELPER="$ROOT/scripts/milmit-surfshark-helper"
INSTALLED_HELPER="/usr/libexec/milmit-surfshark-helper"
if [[ ! -f "$INSTALLED_HELPER" ]] || ! cmp -s "$SOURCE_HELPER" "$INSTALLED_HELPER"; then
  echo "Backend helper changed; installing the current protected backend once..."
  pkexec /bin/bash "$ROOT/scripts/install-privileged-helper.sh"
fi

ICON="$TAURI_DIR/icons/icon.png"
if [[ ! -f "$ICON" ]]; then
  echo "Generating temporary Tauri development icon..."
  command -v python3 >/dev/null 2>&1 || { sudo apt-get update; sudo apt-get install -y python3; }
  mkdir -p "$(dirname "$ICON")"
  ICON_PATH="$ICON" python3 - <<'PY'
import os, struct, zlib, binascii
path=os.environ['ICON_PATH'];w=h=32;raw=bytearray()
for y in range(h):
    raw.append(0)
    for x in range(w): raw.extend((46,125,95,255) if 6<=x<26 and 5<=y<27 else (25,46,69,255))
def chunk(k,d): return struct.pack('>I',len(d))+k+d+struct.pack('>I',binascii.crc32(k+d)&0xffffffff)
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(bytes(raw),9))+chunk(b'IEND',b'')
open(path,'wb').write(png)
PY
fi

[ -d node_modules ] || npm install
exec npm run tauri dev
