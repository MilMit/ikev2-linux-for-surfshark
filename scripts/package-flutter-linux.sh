#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="$ROOT/dist/flutter-linux"
DIST="$ROOT/dist/packages"
VERSION="${VERSION:-0.1.0}"
ARCH="${ARCH:-amd64}"
APP_NAME="milmit-vpn"

[[ -d "$BASE/app" ]] || bash "$ROOT/scripts/build-flutter-linux-release.sh"
rm -rf "$DIST"
mkdir -p "$DIST"

# Debian package
DEBROOT="$DIST/debroot"
mkdir -p "$DEBROOT/DEBIAN" "$DEBROOT/opt/milmit-vpn" "$DEBROOT/usr/bin" "$DEBROOT/usr/share/applications"
cp -a "$BASE/app" "$DEBROOT/opt/milmit-vpn/"
cp -a "$BASE/privileged" "$DEBROOT/opt/milmit-vpn/"
cat > "$DEBROOT/usr/bin/milmit-vpn" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
APP_DIR=/opt/milmit-vpn
export LD_LIBRARY_PATH="$APP_DIR/app/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$APP_DIR/app/milmit_vpn_client" "$@"
SH
chmod 0755 "$DEBROOT/usr/bin/milmit-vpn"
cat > "$DEBROOT/usr/share/applications/milmit-vpn.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=MilMit VPN
Comment=Multi-provider VPN client
Exec=milmit-vpn
Icon=network-vpn
Terminal=false
Categories=Network;Security;
EOF
cat > "$DEBROOT/DEBIAN/control" <<EOF
Package: $APP_NAME
Version: $VERSION
Section: net
Priority: optional
Architecture: $ARCH
Maintainer: MilMit
Depends: policykit-1, iproute2, iptables, strongswan-swanctl, wireguard-tools, openvpn, curl, systemd
Description: MilMit cross-platform VPN client
 Flutter desktop client with Rust core and privileged Linux networking helpers.
EOF
cat > "$DEBROOT/DEBIAN/postinst" <<'SH'
#!/usr/bin/env bash
set -e
bash /opt/milmit-vpn/privileged/scripts/install-privileged-helper.sh || true
exit 0
SH
chmod 0755 "$DEBROOT/DEBIAN/postinst"
dpkg-deb --build --root-owner-group "$DEBROOT" "$DIST/${APP_NAME}_${VERSION}_${ARCH}.deb"

# AppImage: GUI is portable; privileged helper installation remains an explicit first-run/admin action.
APPDIR="$DIST/AppDir"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib/milmit-vpn" "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/256x256/apps"
cp -a "$BASE/app/." "$APPDIR/usr/lib/milmit-vpn/"
cp -a "$BASE/privileged" "$APPDIR/usr/lib/milmit-vpn/"
cat > "$APPDIR/usr/bin/milmit-vpn" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib/milmit-vpn" && pwd)"
export LD_LIBRARY_PATH="$HERE/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$HERE/milmit_vpn_client" "$@"
SH
chmod 0755 "$APPDIR/usr/bin/milmit-vpn"
cat > "$APPDIR/milmit-vpn.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=MilMit VPN
Comment=Multi-provider VPN client
Exec=milmit-vpn
Icon=milmit-vpn
Terminal=false
Categories=Network;Security;
EOF
cp "$APPDIR/milmit-vpn.desktop" "$APPDIR/usr/share/applications/"
cat > "$APPDIR/AppRun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/usr/bin/milmit-vpn" "$@"
SH
chmod 0755 "$APPDIR/AppRun"

# Use a simple generated SVG icon if the Flutter scaffold has no release icon yet.
cat > "$APPDIR/milmit-vpn.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256"><rect width="256" height="256" rx="48"/><path d="M128 38l72 26v52c0 50-28 82-72 104-44-22-72-54-72-104V64l72-26zm0 40a34 34 0 00-18 63v31h36v-31a34 34 0 00-18-63z" fill="white"/></svg>
EOF
cp "$APPDIR/milmit-vpn.svg" "$APPDIR/usr/share/icons/hicolor/256x256/apps/milmit-vpn.svg"

APPIMAGETOOL="${APPIMAGETOOL:-appimagetool}"
if ! command -v "$APPIMAGETOOL" >/dev/null 2>&1; then
  echo "appimagetool not found; DEB was built, AppImage skipped." >&2
else
  ARCH=x86_64 "$APPIMAGETOOL" "$APPDIR" "$DIST/MilMit-VPN-${VERSION}-x86_64.AppImage"
fi

sha256sum "$DIST"/*.deb "$DIST"/*.AppImage 2>/dev/null > "$DIST/SHA256SUMS.txt" || sha256sum "$DIST"/*.deb > "$DIST/SHA256SUMS.txt"
echo "Packages created under: $DIST"
