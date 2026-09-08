#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/apps/flutter"
OUT="$ROOT/dist/flutter-linux"

command -v flutter >/dev/null 2>&1 || { echo "flutter is required" >&2; exit 1; }
command -v cargo >/dev/null 2>&1 || { echo "cargo is required" >&2; exit 1; }

if [[ ! -d "$APP/linux" ]]; then
  echo "Generating Flutter Linux platform scaffold..."
  (cd "$APP" && flutter create --platforms=linux .)
fi

(cd "$APP" && flutter pub get)
(cd "$ROOT" && cargo build -p milmit-vpn-flutter-ffi --release)
(cd "$APP" && flutter build linux --release)

BUNDLE="$APP/build/linux/x64/release/bundle"
[[ -d "$BUNDLE" ]] || { echo "Flutter Linux bundle not found at $BUNDLE" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/app/lib" "$OUT/privileged/scripts" "$OUT/privileged/packaging"
cp -a "$BUNDLE/." "$OUT/app/"
cp "$ROOT/target/release/libmilmit_vpn_flutter_ffi.so" "$OUT/app/lib/"

cp "$ROOT/scripts/install-privileged-helper.sh" "$OUT/privileged/scripts/"
cp "$ROOT/scripts/milmit-surfshark-helper" "$OUT/privileged/scripts/"
cp "$ROOT/scripts/milmit-vpn-platform-helper" "$OUT/privileged/scripts/"
cp "$ROOT/scripts/connection-engine-v3.py" "$OUT/privileged/scripts/"
cp "$ROOT/scripts/protocol-connect-v1.py" "$OUT/privileged/scripts/"
cp "$ROOT/packaging/net.milmit.surfshark-ikev2.policy" "$OUT/privileged/packaging/"

cat > "$OUT/install.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR=/opt/milmit-vpn
sudo install -d -m 0755 "$APP_DIR"
sudo cp -a "$ROOT/app/." "$APP_DIR/"
if [[ -x "$ROOT/privileged/scripts/install-privileged-helper.sh" ]]; then
  sudo bash "$ROOT/privileged/scripts/install-privileged-helper.sh"
fi
echo "Flutter Linux app installed under $APP_DIR"
SH
chmod +x "$OUT/install.sh"

tar -C "$ROOT/dist" -czf "$ROOT/dist/milmit-vpn-flutter-linux.tar.gz" flutter-linux

echo "Created: $ROOT/dist/milmit-vpn-flutter-linux.tar.gz"
