#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE="$ROOT/native/macos"
DERIVED="$NATIVE/build"
OUT="$NATIVE/out"
WG_VENDOR="$NATIVE/vendor/wireguard-apple"
WG_REV="2fec12a6e1f6e3460b6ee483aa00ad29cddadab1"

[[ "$(uname -s)" == "Darwin" ]] || { echo "PacketTunnel build requires macOS" >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "xcodegen is required" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "xcodebuild is required" >&2; exit 1; }
command -v go >/dev/null || { echo "Go is required to build WireGuardKitGo" >&2; exit 1; }

rm -rf "$NATIVE/MilMitVPNNative.xcodeproj" "$DERIVED" "$OUT" "$WG_VENDOR"
mkdir -p "$OUT" "$NATIVE/vendor"

git clone --filter=blob:none https://github.com/WireGuard/wireguard-apple.git "$WG_VENDOR"
git -C "$WG_VENDOR" checkout "$WG_REV"
python3 - "$WG_VENDOR/Package.swift" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
if text.startswith('// swift-tools-version:5.3'):
    p.write_text(text.replace('// swift-tools-version:5.3', '// swift-tools-version:5.5', 1))
elif not text.startswith('// swift-tools-version:5.5'):
    raise SystemExit('unexpected WireGuardKit Package.swift header')
PY

(
  cd "$NATIVE"
  xcodegen generate --spec project.yml
)

for scheme in PacketTunnel OpenVPNPacketTunnel; do
  xcodebuild \
    -resolvePackageDependencies \
    -project "$NATIVE/MilMitVPNNative.xcodeproj" \
    -scheme "$scheme" \
    -clonedSourcePackagesDirPath "$DERIVED/SourcePackages"

  xcodebuild \
    -project "$NATIVE/MilMitVPNNative.xcodeproj" \
    -scheme "$scheme" \
    -configuration Release \
    -derivedDataPath "$DERIVED/DerivedData" \
    -clonedSourcePackagesDirPath "$DERIVED/SourcePackages" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

done

for name in PacketTunnel OpenVPNPacketTunnel; do
  APPEX="$(find "$DERIVED/DerivedData/Build/Products/Release" -maxdepth 3 -name "$name.appex" -print -quit)"
  [[ -n "$APPEX" && -d "$APPEX" ]] || { echo "$name.appex was not produced" >&2; exit 1; }
  cp -R "$APPEX" "$OUT/$name.appex"
  echo "Created: $OUT/$name.appex"
done
