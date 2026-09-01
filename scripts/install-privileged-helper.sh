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
  if ((${#missing[@]})); then DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >/dev/null 2>&1 || true; fi
fi

install -d -m 0755 /usr/lib/milmit-surfshark /usr/libexec /usr/share/polkit-1/actions "$RULES_DIR" "$EXT_DIR" /var/lib/milmit-surfshark /var/lib/milmit-surfshark/rules
for f in restricted-ikev2-connect.sh restricted-ikev2-connect-v2.sh restricted-ikev2-disconnect.sh hotspot-device-policy.sh milmit-surfshark-watchdog.sh control-center.py router-features.py advanced-router.py rules-update.py status-portal.py; do
  install -o root -g root -m 0755 "$ROOT/scripts/$f" "/usr/lib/milmit-surfshark/$f"
done
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
for unit in milmit-surfshark-watchdog.service milmit-surfshark-rules-update.service milmit-surfshark-rules-update.timer milmit-surfshark-portal.service milmit-surfshark-keepawake.service; do
  install -o root -g root -m 0644 "$ROOT/packaging/$unit" "/etc/systemd/system/$unit"
done

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable milmit-surfshark-watchdog.service >/dev/null 2>&1 || true
# Backend/watchdog files are replaced during an upgrade. Restart even when the
# service is already active so the installed code is the code actually running.
systemctl restart milmit-surfshark-watchdog.service >/dev/null 2>&1 || true
systemctl enable --now milmit-surfshark-rules-update.timer >/dev/null 2>&1 || true
systemctl enable --now milmit-surfshark-portal.service >/dev/null 2>&1 || true
systemctl disable --now milmit-surfshark-keepawake.service >/dev/null 2>&1 || true
systemctl try-reload-or-restart polkit.service >/dev/null 2>&1 || true

if [[ ! -s /var/lib/milmit-surfshark/rules/ircidr.txt ]]; then /usr/lib/milmit-surfshark/rules-update.py update >/var/log/milmit-surfshark-rules-update.log 2>&1 || true; fi

echo "MilMit Surfshark privileged helper and full native router protection stack installed."
echo "Authorization model: install/update may ask once; connect/disconnect/tools are passwordless for the active local sudo user."
command -v ipset >/dev/null 2>&1 && echo "Iran Direct: ipset ready." || echo "Iran Direct: ipset missing."
command -v tc >/dev/null 2>&1 && echo "Per-device shaping: tc ready." || echo "Per-device shaping: tc unavailable."
command -v conntrack >/dev/null 2>&1 && echo "Candidate feed / connection repair: conntrack ready." || true
command -v qrencode >/dev/null 2>&1 && echo "Guest QR support: qrencode ready." || true
systemctl is-active --quiet milmit-surfshark-watchdog.service 2>/dev/null && echo "Watchdog: active · recovery + telemetry + quota enforcement."
systemctl is-active --quiet milmit-surfshark-portal.service 2>/dev/null && echo "Local status portal: active on TCP 8787 (loopback/hotspot clients only)."
echo "Feature stack: transactional Apply Safely + live verification, LKG, Iran local snapshot + weekly validated refresh, policy priority, VPN/Direct/Block rules, device controls, quota/throttle, shaping, Guest Hotspot, Force DNS, QUIC/IPv6 protection, isolation, candidates, route explain/test, watchdog, diagnostics, support bundle, status portal, low-power controls and Emergency Stop."
