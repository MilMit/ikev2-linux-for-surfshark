#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run this installer through pkexec." >&2; exit 77; fi
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
EXT_UUID=surfshark-ikev2@milmit.net
EXT_DIR="/usr/share/gnome-shell/extensions/$EXT_UUID"
RULES_DIR=/etc/polkit-1/rules.d
RULES_FILE="$RULES_DIR/49-milmit-surfshark.rules"

if command -v apt-get >/dev/null 2>&1; then
  missing=()
  command -v ipset >/dev/null 2>&1 || missing+=(ipset)
  command -v tc >/dev/null 2>&1 || missing+=(iproute2)
  command -v conntrack >/dev/null 2>&1 || missing+=(conntrack)
  command -v qrencode >/dev/null 2>&1 || missing+=(qrencode)
  command -v openvpn >/dev/null 2>&1 || missing+=(openvpn)
  command -v wg-quick >/dev/null 2>&1 || missing+=(wireguard-tools)
  command -v ike-scan >/dev/null 2>&1 || missing+=(ike-scan)
  if ((${#missing[@]})); then DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >/dev/null 2>&1 || true; fi
fi

install -d -m 0755 /usr/lib/milmit-surfshark /usr/libexec /usr/share/polkit-1/actions "$RULES_DIR" "$EXT_DIR" /var/lib/milmit-surfshark /var/lib/milmit-surfshark/rules /usr/lib/systemd/system-sleep
install -d -o root -g root -m 0700 /etc/milmit-surfshark /etc/milmit-surfshark/openvpn /etc/milmit-surfshark/wireguard
for f in restricted-ikev2-connect.sh restricted-ikev2-connect-v2.sh restricted-ikev2-disconnect.sh connection-engine-v3.py secure-endpoint-discovery.py hotspot-device-policy.sh milmit-surfshark-watchdog.sh milmit-surfshark-sleep-hook.sh control-center.py router-features.py advanced-router.py rules-update.py status-portal.py desktop-features.py hotspot-doctor.py; do
  install -o root -g root -m 0755 "$ROOT/scripts/$f" "/usr/lib/milmit-surfshark/$f"
done
install -o root -g root -m 0755 "$ROOT/scripts/milmit-surfshark-sleep-hook.sh" /usr/lib/systemd/system-sleep/milmit-surfshark
install -o root -g root -m 0755 "$ROOT/scripts/install-privileged-helper.sh" /usr/lib/milmit-surfshark/install-privileged-helper.sh
install -o root -g root -m 0755 "$ROOT/scripts/hotspot-device-manager.py" /usr/lib/milmit-surfshark/hotspot-device-manager.py
install -o root -g root -m 0755 "$ROOT/scripts/milmit-surfshark-helper" /usr/libexec/milmit-surfshark-helper
install -o root -g root -m 0644 "$ROOT/packaging/net.milmit.surfshark-ikev2.policy" /usr/share/polkit-1/actions/net.milmit.surfshark-ikev2.policy
cat > "$RULES_FILE" <<'RULE'
polkit.addRule(function(action, subject) {
    if (action.id == "net.milmit.surfshark-ikev2.manage" &&
        subject.active && subject.local && subject.isInGroup("sudo")) {
        return polkit.Result.YES;
    }
});
RULE
chmod 0644 "$RULES_FILE"
install -o root -g root -m 0644 "$ROOT/packaging/gnome-shell-extension/metadata.json" "$EXT_DIR/metadata.json"
install -o root -g root -m 0644 "$ROOT/packaging/gnome-shell-extension/extension.js" "$EXT_DIR/extension.js"
for unit in milmit-surfshark-watchdog.service milmit-surfshark-rules-update.service milmit-surfshark-rules-update.timer milmit-surfshark-portal.service milmit-surfshark-keepawake.service milmit-surfshark-autoconnect.service; do
  install -o root -g root -m 0644 "$ROOT/packaging/$unit" "/etc/systemd/system/$unit"
done
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable milmit-surfshark-watchdog.service >/dev/null 2>&1 || true
systemctl restart milmit-surfshark-watchdog.service >/dev/null 2>&1 || true
systemctl enable --now milmit-surfshark-rules-update.timer >/dev/null 2>&1 || true
systemctl enable --now milmit-surfshark-portal.service >/dev/null 2>&1 || true
systemctl disable --now milmit-surfshark-keepawake.service >/dev/null 2>&1 || true
if [[ -f /var/lib/milmit-surfshark/desktop-features.json ]] && grep -q '"auto_connect"[[:space:]]*:[[:space:]]*true' /var/lib/milmit-surfshark/desktop-features.json; then systemctl enable milmit-surfshark-autoconnect.service >/dev/null 2>&1 || true; else systemctl disable milmit-surfshark-autoconnect.service >/dev/null 2>&1 || true; fi
systemctl try-reload-or-restart polkit.service >/dev/null 2>&1 || true
if [[ ! -s /var/lib/milmit-surfshark/rules/ircidr.txt ]]; then /usr/lib/milmit-surfshark/rules-update.py update >/var/log/milmit-surfshark-rules-update.log 2>&1 || true; fi
/usr/lib/milmit-surfshark/desktop-features.py lockdown-apply >/dev/null 2>&1 || true

echo "MilMit Surfshark privileged helper and Connection Engine v3 installed."
echo "Secure endpoint discovery now uses multiple independent DoH resolvers with DNS-over-TLS fallback."
echo "Location latency now probes the actual IKEv2 service instead of trusting ICMP ping alone."
echo "Fallback transports: WireGuard/OpenVPN engines are available when matching manual profiles are present under /etc/milmit-surfshark/."
echo "Suspend/resume recovery hook installed; screen lock leaves the tunnel running and sleep recovery is automatic."
echo "Authorization model: install/update may ask once; connect/disconnect/tools are passwordless for the active local sudo user."
