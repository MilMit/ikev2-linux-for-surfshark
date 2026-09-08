#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE="$ROOT/native/macos"
DERIVED="$NATIVE/build"
OUT="$NATIVE/out"

[[ "$(uname -s)" == "Darwin" ]] || { echo "PacketTunnel build requires macOS" >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "xcodegen is required" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "xcodebuild is required" >&2; exit 1; }
command -v go >/dev/null || { echo "Go is required to build WireGuardKitGo" >&2; exit 1; }

rm -rf "$NATIVE/MilMitVPNNative.xcodeproj" "$DERIVED" "$OUT"
mkdir -p "$OUT"

(
  cd "$NATIVE"
  xcodegen generate --spec project.yml
)

xcodebuild \
  -resolvePackageDependencies \
  -project "$NATIVE/MilMitVPNNative.xcodeproj" \
  -scheme PacketTunnel \
  -clonedSourcePackagesDirPath "$DERIVED/SourcePackages"

xcodebuild \
  -project "$NATIVE/MilMitVPNNative.xcodeproj" \
  -scheme PacketTunnel \
  -configuration Release \
  -derivedDataPath "$DERIVED/DerivedData" \
  -clonedSourcePackagesDirPath "$DERIVED/SourcePackages" \
  CODE_SIGNING_ALLOWED=NO \
  build

APPEX="$(find "$DERIVED/DerivedData/Build/Products/Release" -maxdepth 2 -name 'PacketTunnel.appex' -print -quit)"
[[ -n "$APPEX" && -d "$APPEX" ]] || { echo "PacketTunnel.appex was not produced" >&2; exit 1; }
cp -R "$APPEX" "$OUT/PacketTunnel.appex"

echo "Created: $OUT/PacketTunnel.appex"
