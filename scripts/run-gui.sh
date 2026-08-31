#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER=/usr/libexec/milmit-surfshark-helper
INSTALLED_CONNECT=/usr/lib/milmit-surfshark/restricted-ikev2-connect.sh
INSTALLED_DISCONNECT=/usr/lib/milmit-surfshark/restricted-ikev2-disconnect.sh
EXT_UUID=surfshark-ikev2@milmit.net
EXT_DIR="/usr/share/gnome-shell/extensions/$EXT_UUID"
SHIM="$ROOT/scripts/pkexec-shim/pkexec"
TRAY="$ROOT/scripts/tray-indicator.py"

chmod 0755 "$SHIM"
chmod 0755 "$TRAY" 2>/dev/null || true

needs_install=0
if [[ ! -x "$HELPER" || ! -f "$INSTALLED_CONNECT" || ! -f "$INSTALLED_DISCONNECT" ]]; then
  needs_install=1
elif [[ ! -f "$EXT_DIR/extension.js" || ! -f "$EXT_DIR/metadata.json" ]]; then
  needs_install=1
elif ! cmp -s "$ROOT/scripts/restricted-ikev2-connect.sh" "$INSTALLED_CONNECT"; then
  needs_install=1
elif ! cmp -s "$ROOT/scripts/restricted-ikev2-disconnect.sh" "$INSTALLED_DISCONNECT"; then
  needs_install=1
elif ! cmp -s "$ROOT/scripts/milmit-surfshark-helper" "$HELPER"; then
  needs_install=1
elif ! cmp -s "$ROOT/packaging/gnome-shell-extension/extension.js" "$EXT_DIR/extension.js"; then
  needs_install=1
fi

if [[ "$needs_install" == 1 ]]; then
  echo "VPN helper/indicator install or update: Ubuntu may ask for your password once."
  /usr/bin/pkexec /usr/bin/bash "$ROOT/scripts/install-privileged-helper.sh"
fi

# Prefer a native GNOME Shell top-bar status icon. On a brand-new extension
# install, GNOME Shell can require a new login session before it loads the
# extension. In that case launch an AppIndicator fallback immediately so the
# user still sees VPN status in Ubuntu's top bar during this session.
extension_enabled=0
if command -v gnome-extensions >/dev/null 2>&1; then
  gnome-extensions enable "$EXT_UUID" >/dev/null 2>&1 || true
  if gnome-extensions list --enabled 2>/dev/null | grep -Fxq "$EXT_UUID"; then
    extension_enabled=1
  fi
fi

if [[ "$extension_enabled" == 0 ]] && command -v python3 >/dev/null 2>&1; then
  nohup python3 "$TRAY" >/tmp/milmit-surfshark-indicator.log 2>&1 &
fi

export PATH="$ROOT/scripts/pkexec-shim:$PATH"
cd "$ROOT"
exec cargo run -p surfshark-ikev2-gui
