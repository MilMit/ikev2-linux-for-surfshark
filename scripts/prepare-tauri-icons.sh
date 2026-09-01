#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICON_DIR="$ROOT/apps/desktop/src-tauri/icons"
SVG="$ICON_DIR/icon.svg"

[[ -f "$SVG" ]] || { echo "Missing icon source: $SVG" >&2; exit 1; }
command -v rsvg-convert >/dev/null 2>&1 || { echo "rsvg-convert is required (Ubuntu: sudo apt install librsvg2-bin)" >&2; exit 1; }

mkdir -p "$ICON_DIR"
rsvg-convert -w 32  -h 32  "$SVG" -o "$ICON_DIR/32x32.png"
rsvg-convert -w 128 -h 128 "$SVG" -o "$ICON_DIR/128x128.png"
rsvg-convert -w 256 -h 256 "$SVG" -o "$ICON_DIR/128x128@2x.png"
rsvg-convert -w 512 -h 512 "$SVG" -o "$ICON_DIR/icon.png"

echo "Tauri Linux icons rendered from icon.svg (32, 128, 256, 512 px)."
