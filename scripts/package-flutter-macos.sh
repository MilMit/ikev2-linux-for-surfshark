#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/apps/flutter"
DIST="$ROOT/dist/macos"
VERSION="${VERSION:-0.1.0}"
SIGN_IDENTITY="${MACOS_SIGN_IDENTITY:-}"

[[ "$(uname -s)" == "Darwin" ]] || { echo "macOS packaging must run on macOS" >&2; exit 1; }
command -v flutter >/dev/null || { echo "flutter is required" >&2; exit 1; }
command -v cargo >/dev/null || { echo "cargo is required" >&2; exit 1; }

if [[ ! -d "$APP/macos" ]]; then
  (cd "$APP" && flutter create --platforms=macos .)
fi

(cd "$APP" && flutter pub get && flutter build macos --release)
(cd "$ROOT" && cargo build -p milmit-vpn-flutter-ffi --release)

APP_BUNDLE="$(find "$APP/build/macos/Build/Products/Release" -maxdepth 1 -name '*.app' -print -quit)"
[[ -n "$APP_BUNDLE" && -d "$APP_BUNDLE" ]] || { echo "Flutter macOS .app bundle not found" >&2; exit 1; }

rm -rf "$DIST"
mkdir -p "$DIST"
cp -R "$APP_BUNDLE" "$DIST/MilMit VPN.app"
cp "$ROOT/target/release/libmilmit_vpn_flutter_ffi.dylib" "$DIST/MilMit VPN.app/Contents/Frameworks/"

if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$DIST/MilMit VPN.app/Contents/Frameworks/libmilmit_vpn_flutter_ffi.dylib"
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$DIST/MilMit VPN.app"
else
  # CI/dev builds remain installable locally but are not notarized distribution builds.
  codesign --force --deep --sign - "$DIST/MilMit VPN.app"
fi

hdiutil create -volname "MilMit VPN" -srcfolder "$DIST/MilMit VPN.app" -ov -format UDZO "$DIST/MilMit-VPN-${VERSION}.dmg"
shasum -a 256 "$DIST/MilMit-VPN-${VERSION}.dmg" > "$DIST/SHA256SUMS.txt"

echo "Created macOS app: $DIST/MilMit VPN.app"
echo "Created DMG: $DIST/MilMit-VPN-${VERSION}.dmg"
