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
cp -a "$ROOT/scripts/." "$OUT/privileged/scripts/"
cp -a "$ROOT/packaging/." "$OUT/privileged/packaging/"

cat > "$OUT/run.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LD_LIBRARY_PATH="$ROOT/app/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$ROOT/app/milmit_vpn_client" "$@"
SH
chmod +x "$OUT/run.sh"

cat > "$OUT/install.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR=/opt/milmit-vpn
sudo install -d -m 0755 "$APP_DIR"
sudo rm -rf "$APP_DIR/app" "$APP_DIR/privileged"
sudo cp -a "$ROOT/app" "$APP_DIR/"
sudo cp -a "$ROOT/privileged" "$APP_DIR/"
sudo tee /usr/bin/milmit-vpn >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
APP_DIR=/opt/milmit-vpn
export LD_LIBRARY_PATH="$APP_DIR/app/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$APP_DIR/app/milmit_vpn_client" "$@"
EOF
sudo chmod 0755 /usr/bin/milmit-vpn
sudo bash "$APP_DIR/privileged/scripts/install-privileged-helper.sh"
echo "Flutter Linux app installed. Launch with: milmit-vpn"
SH
chmod +x "$OUT/install.sh"

tar -C "$ROOT/dist" -czf "$ROOT/dist/milmit-vpn-flutter-linux.tar.gz" flutter-linux

echo "Created: $ROOT/dist/milmit-vpn-flutter-linux.tar.gz"
