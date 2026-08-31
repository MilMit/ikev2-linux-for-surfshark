#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER=/usr/libexec/milmit-surfshark-helper
INSTALLED_CONNECT=/usr/lib/milmit-surfshark/restricted-ikev2-connect.sh
INSTALLED_DISCONNECT=/usr/lib/milmit-surfshark/restricted-ikev2-disconnect.sh
EXT_UUID=surfshark-ikev2@milmit.net
EXT_DIR="/usr/share/gnome-shell/extensions/$EXT_UUID"
TRAY="$ROOT/scripts/tray-indicator.py"
RUNTIME_SHIM_DIR="${XDG_RUNTIME_DIR:-/tmp}/milmit-surfshark-$UID"
RUNTIME_SHIM="$RUNTIME_SHIM_DIR/pkexec"

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

if [[ ! -x "$HELPER" ]] \
  || ! cmp -s "$ROOT/scripts/restricted-ikev2-connect.sh" "$INSTALLED_CONNECT" \
  || ! cmp -s "$ROOT/scripts/restricted-ikev2-disconnect.sh" "$INSTALLED_DISCONNECT" \
  || ! cmp -s "$ROOT/scripts/milmit-surfshark-helper" "$HELPER"; then
  echo "ERROR: privileged VPN helper is stale or installation did not complete." >&2
  echo "Run this launcher again and approve the one-time Ubuntu authorization." >&2
  exit 78
fi

echo "MilMit privileged VPN helper: verified and current."

install -d -m 0700 "$RUNTIME_SHIM_DIR"
cat >"$RUNTIME_SHIM" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
REAL_PKEXEC=/usr/bin/pkexec
HELPER=/usr/libexec/milmit-surfshark-helper
if [[ "${1:-}" == "bash" && -n "${2:-}" ]]; then
  script="${2}"
  case "$script" in
    */scripts/restricted-ikev2-connect.sh)
      endpoint="${3:-}"
      username="${4:-}"
      mss="${5:-1200}"
      dns_csv="${6:-162.252.172.57,149.154.159.92}"
      hotspot_vpn="${7:-1}"
      recover_network="${8:-1}"
      hotspot_iface="${9:-auto}"
      kill_switch="${10:-0}"
      routing_mode="${11:-vpn_all}"
      hotspot_vpn_macs="${12:-}"
      hotspot_direct_macs="${13:-}"
      exec "$REAL_PKEXEC" "$HELPER" connect "$endpoint" "$username" "$mss" "$dns_csv" "$hotspot_vpn" "$recover_network" "$hotspot_iface" "$kill_switch" "$routing_mode" "$hotspot_vpn_macs" "$hotspot_direct_macs"
      ;;
    */scripts/restricted-ikev2-disconnect.sh)
      exec "$REAL_PKEXEC" "$HELPER" disconnect
      ;;
  esac
fi
exec "$REAL_PKEXEC" "$@"
SHIM
chmod 0755 "$RUNTIME_SHIM"

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

export PATH="$RUNTIME_SHIM_DIR:$PATH"
cd "$ROOT"
exec cargo run -p surfshark-ikev2-gui
