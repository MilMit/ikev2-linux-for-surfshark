#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER=/usr/libexec/milmit-surfshark-helper
INSTALLED_CONNECT=/usr/lib/milmit-surfshark/restricted-ikev2-connect.sh
INSTALLED_CONNECT_V2=/usr/lib/milmit-surfshark/restricted-ikev2-connect-v2.sh
INSTALLED_DISCONNECT=/usr/lib/milmit-surfshark/restricted-ikev2-disconnect.sh
INSTALLED_DEVICE_POLICY=/usr/lib/milmit-surfshark/hotspot-device-policy.sh
INSTALLED_DEVICE_MANAGER=/usr/lib/milmit-surfshark/hotspot-device-manager.py
INSTALLED_WATCHDOG=/usr/lib/milmit-surfshark/milmit-surfshark-watchdog.sh
INSTALLED_CONTROL=/usr/lib/milmit-surfshark/control-center.py
INSTALLED_ROUTER=/usr/lib/milmit-surfshark/router-features.py
INSTALLED_ADV=/usr/lib/milmit-surfshark/advanced-router.py
INSTALLED_RULES=/usr/lib/milmit-surfshark/rules-update.py
INSTALLED_PORTAL=/usr/lib/milmit-surfshark/status-portal.py
INSTALLED_INSTALLER=/usr/lib/milmit-surfshark/install-privileged-helper.sh
WATCHDOG_UNIT=/etc/systemd/system/milmit-surfshark-watchdog.service
RULES_TIMER=/etc/systemd/system/milmit-surfshark-rules-update.timer
PORTAL_UNIT=/etc/systemd/system/milmit-surfshark-portal.service
EXT_UUID=surfshark-ikev2@milmit.net
EXT_DIR="/usr/share/gnome-shell/extensions/$EXT_UUID"
TRAY="$ROOT/scripts/tray-indicator.py"
RUNTIME_SHIM_DIR="${XDG_RUNTIME_DIR:-/tmp}/milmit-surfshark-$UID"
RUNTIME_SHIM="$RUNTIME_SHIM_DIR/pkexec"
chmod 0755 "$TRAY" 2>/dev/null || true

needs_install=0
for spec in "$HELPER:$ROOT/scripts/milmit-surfshark-helper" "$INSTALLED_CONNECT:$ROOT/scripts/restricted-ikev2-connect.sh" "$INSTALLED_CONNECT_V2:$ROOT/scripts/restricted-ikev2-connect-v2.sh" "$INSTALLED_DISCONNECT:$ROOT/scripts/restricted-ikev2-disconnect.sh" "$INSTALLED_DEVICE_POLICY:$ROOT/scripts/hotspot-device-policy.sh" "$INSTALLED_DEVICE_MANAGER:$ROOT/scripts/hotspot-device-manager.py" "$INSTALLED_WATCHDOG:$ROOT/scripts/milmit-surfshark-watchdog.sh" "$INSTALLED_CONTROL:$ROOT/scripts/control-center.py" "$INSTALLED_ROUTER:$ROOT/scripts/router-features.py" "$INSTALLED_ADV:$ROOT/scripts/advanced-router.py" "$INSTALLED_RULES:$ROOT/scripts/rules-update.py" "$INSTALLED_PORTAL:$ROOT/scripts/status-portal.py" "$INSTALLED_INSTALLER:$ROOT/scripts/install-privileged-helper.sh"; do
  installed="${spec%%:*}"; source="${spec#*:}"
  if [[ ! -x "$installed" ]] || ! cmp -s "$source" "$installed"; then needs_install=1; break; fi
done
if [[ "$needs_install" == 0 ]]; then
  [[ -f "$WATCHDOG_UNIT" && -f "$RULES_TIMER" && -f "$PORTAL_UNIT" ]] || needs_install=1
  [[ -f "$EXT_DIR/extension.js" && -f "$EXT_DIR/metadata.json" ]] || needs_install=1
fi
if [[ "$needs_install" == 0 ]] && ! cmp -s "$ROOT/packaging/gnome-shell-extension/extension.js" "$EXT_DIR/extension.js"; then needs_install=1; fi
if [[ "$needs_install" == 1 ]]; then
  echo "VPN/full router protection stack update: Ubuntu may ask for your password once."
  /usr/bin/pkexec /usr/bin/bash "$ROOT/scripts/install-privileged-helper.sh"
fi
for spec in "$HELPER:$ROOT/scripts/milmit-surfshark-helper" "$INSTALLED_CONNECT_V2:$ROOT/scripts/restricted-ikev2-connect-v2.sh" "$INSTALLED_ROUTER:$ROOT/scripts/router-features.py" "$INSTALLED_ADV:$ROOT/scripts/advanced-router.py" "$INSTALLED_RULES:$ROOT/scripts/rules-update.py" "$INSTALLED_PORTAL:$ROOT/scripts/status-portal.py"; do
  installed="${spec%%:*}"; source="${spec#*:}"
  if [[ ! -x "$installed" ]] || ! cmp -s "$source" "$installed"; then echo "ERROR: privileged router stack is stale or installation did not complete: $installed" >&2; exit 78; fi
done
systemctl is-active --quiet milmit-surfshark-watchdog.service 2>/dev/null || /usr/bin/pkexec "$HELPER" watchdog-start >/dev/null 2>&1 || true
systemctl is-active --quiet milmit-surfshark-portal.service 2>/dev/null || /usr/bin/pkexec "$HELPER" portal-start >/dev/null 2>&1 || true
echo "MilMit VPN + native router protection stack: verified and current."

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
      endpoint="${3:-}"; username="${4:-}"; mss="${5:-1200}"; dns_csv="${6:-162.252.172.57,149.154.159.92}"; hotspot_vpn="${7:-1}"; recover_network="${8:-1}"; hotspot_iface="${9:-auto}"; kill_switch="${10:-0}"; routing_mode="${11:-vpn_all}"; hotspot_vpn_macs="${12:-}"; hotspot_direct_macs="${13:-}"
      echo "MILMIT_BACKEND=v2-helper" >&2
      exec "$REAL_PKEXEC" "$HELPER" connect "$endpoint" "$username" "$mss" "$dns_csv" "$hotspot_vpn" "$recover_network" "$hotspot_iface" "$kill_switch" "$routing_mode" "$hotspot_vpn_macs" "$hotspot_direct_macs"
      ;;
    */scripts/restricted-ikev2-disconnect.sh) exec "$REAL_PKEXEC" "$HELPER" disconnect ;;
  esac
fi
exec "$REAL_PKEXEC" "$@"
SHIM
chmod 0755 "$RUNTIME_SHIM"
extension_enabled=0
if command -v gnome-extensions >/dev/null 2>&1; then gnome-extensions enable "$EXT_UUID" >/dev/null 2>&1 || true; if gnome-extensions list --enabled 2>/dev/null | grep -Fxq "$EXT_UUID"; then extension_enabled=1; fi; fi
if [[ "$extension_enabled" == 0 ]] && command -v python3 >/dev/null 2>&1; then nohup python3 "$TRAY" >/tmp/milmit-surfshark-indicator.log 2>&1 & fi
export PATH="$RUNTIME_SHIM_DIR:$PATH"
cd "$ROOT"
exec cargo run -p surfshark-ikev2-gui
