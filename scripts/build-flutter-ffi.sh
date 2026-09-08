#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

cargo build -p milmit-vpn-flutter-ffi --release

case "$(uname -s)" in
  Linux*)
    echo "Built: target/release/libmilmit_vpn_flutter_ffi.so"
    ;;
  Darwin*)
    echo "Built: target/release/libmilmit_vpn_flutter_ffi.dylib"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    echo "Built: target/release/milmit_vpn_flutter_ffi.dll"
    ;;
  *)
    echo "Build completed. Check target/release for the native library."
    ;;
esac
