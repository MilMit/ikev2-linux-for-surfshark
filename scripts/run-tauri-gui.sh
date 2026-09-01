#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/apps/desktop"
TAURI_DIR="$APP/src-tauri"
cd "$APP"

if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required for the new desktop UI." >&2
  exit 1
fi

if ! command -v pkg-config >/dev/null 2>&1; then
  echo "Installing pkg-config..."
  sudo apt-get update
  sudo apt-get install -y pkg-config
fi

# Tauri/WebKitGTK requires these pkg-config modules on Linux. Check the
# modules themselves (not only dpkg state), because a package can be present
# while pkg-config cannot see its .pc file.
need_install=0
for module in webkit2gtk-4.1 libsoup-3.0 javascriptcoregtk-4.1; do
  if ! pkg-config --exists "$module"; then
    need_install=1
  fi
done

if ((need_install)); then
  echo "Installing/repairing required Tauri Linux build dependencies..."
  sudo apt-get update
  sudo apt-get install -y \
    build-essential \
    pkg-config \
    libwebkit2gtk-4.1-dev \
    libjavascriptcoregtk-4.1-dev \
    libsoup-3.0-dev \
    libgtk-3-dev \
    libayatana-appindicator3-dev \
    librsvg2-dev
fi

# Ensure Debian/Ubuntu multiarch pkg-config directories are visible even if
# the shell has a custom PKG_CONFIG_PATH.
MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
pc_paths=("/usr/lib/pkgconfig" "/usr/share/pkgconfig")
if [[ -n "$MULTIARCH" ]]; then
  pc_paths=("/usr/lib/$MULTIARCH/pkgconfig" "${pc_paths[@]}")
fi
for p in "${pc_paths[@]}"; do
  [[ -d "$p" ]] || continue
  case ":${PKG_CONFIG_PATH:-}:" in
    *":$p:"*) ;;
    *) export PKG_CONFIG_PATH="$p${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" ;;
  esac
done

# Fail early with a useful diagnosis instead of a long Rust build failure.
missing_modules=()
for module in webkit2gtk-4.1 libsoup-3.0 javascriptcoregtk-4.1; do
  if ! pkg-config --exists "$module"; then
    missing_modules+=("$module")
  fi
done
if ((${#missing_modules[@]})); then
  echo "ERROR: pkg-config still cannot find: ${missing_modules[*]}" >&2
  echo "PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-<unset>}" >&2
  echo "Installed JavaScriptCore files:" >&2
  dpkg -L libjavascriptcoregtk-4.1-dev 2>/dev/null | grep -E 'javascriptcoregtk-4\.1\.pc$' >&2 || true
  exit 1
fi

echo "Tauri native dependencies detected:"
pkg-config --modversion webkit2gtk-4.1 libsoup-3.0 javascriptcoregtk-4.1

# tauri::generate_context! expects a default application icon at
# src-tauri/icons/icon.png even when bundling is disabled. Generate a tiny
# valid RGBA PNG for development if the real branded icon is not present yet.
ICON="$TAURI_DIR/icons/icon.png"
if [[ ! -f "$ICON" ]]; then
  echo "Generating temporary Tauri development icon..."
  if ! command -v python3 >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y python3
  fi
  mkdir -p "$(dirname "$ICON")"
  ICON_PATH="$ICON" python3 - <<'PY'
import os, struct, zlib, binascii
path = os.environ["ICON_PATH"]
w = h = 32
raw = bytearray()
for y in range(h):
    raw.append(0)
    for x in range(w):
        # simple MilMit development mark: navy background + green center tile
        if 6 <= x < 26 and 5 <= y < 27:
            rgba = (46, 125, 95, 255)
        else:
            rgba = (25, 46, 69, 255)
        raw.extend(rgba)

def chunk(kind, data):
    return (struct.pack(">I", len(data)) + kind + data +
            struct.pack(">I", binascii.crc32(kind + data) & 0xffffffff))

png = (b"\x89PNG\r\n\x1a\n" +
       chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) +
       chunk(b"IDAT", zlib.compress(bytes(raw), 9)) +
       chunk(b"IEND", b""))
with open(path, "wb") as f:
    f.write(png)
PY
fi

if [ ! -d node_modules ]; then
  npm install
fi

exec npm run tauri dev
