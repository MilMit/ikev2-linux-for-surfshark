#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run this installer through pkexec." >&2; exit 77; fi
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
EXT_UUID=surfshark-ikev2@milmit.net
EXT_DIR="/usr/share/gnome-shell/extensions/$EXT_UUID"

if command -v apt-get >/dev/null 2>&1; then
  missing=()
  command -v ipset >/dev/null 2>&1 || missing+=(ipset)
  command -v tc >/dev/null 2>&1 || missing+=(iproute2)
  command -v conntrack >/dev/null 2>&1 || missing+=(conntrack)
  if ((${#missing[@]})); then DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >/dev/null 2>&1 || true; fi
fi

install -d -m 0755 /usr/lib/milmit-surfshark /usr/libexec /usr/share/polkit-1/actions "$EXT_DIR" /var/lib/milmit-surfshark
install -o root -g root -m 0755 "$ROOT/scripts/restricted-ikev2-connect.sh" /usr/lib/milmit-surfshark/restricted-ikev2-connect.sh
install -o root -g root -m 0755 "$ROOT/scripts/restricted-ikev2-connect-v2.sh" /usr/lib/milmit-surfshark/restricted-ikev2-connect-v2.sh
install -o root -g root -m 0755 "$ROOT/scripts/restricted-ikev2-disconnect.sh" /usr/lib/milmit-surfshark/restricted-ikev2-disconnect.sh
install -o root -g root -m 0755 "$ROOT/scripts/hotspot-device-policy.sh" /usr/lib/milmit-surfshark/hotspot-device-policy.sh
install -o root -g root -m 0755 "$ROOT/scripts/hotspot-device-manager.py" /usr/lib/milmit-surfshark/hotspot-device-manager.py
install -o root -g root -m 0755 "$ROOT/scripts/milmit-surfshark-watchdog.sh" /usr/lib/milmit-surfshark/milmit-surfshark-watchdog.sh
install -o root -g root -m 0755 "$ROOT/scripts/control-center.py" /usr/lib/milmit-surfshark/control-center.py
install -o root -g root -m 0755 "$ROOT/scripts/router-features.py" /usr/lib/milmit-surfshark/router-features.py
install -o root -g root -m 0755 "$ROOT/scripts/milmit-surfshark-helper" /usr/libexec/milmit-surfshark-helper
install -o root -g root -m 0644 "$ROOT/packaging/net.milmit.surfshark-ikev2.policy" /usr/share/polkit-1/actions/net.milmit.surfshark-ikev2.policy
install -o root -g root -m 0644 "$ROOT/packaging/gnome-shell-extension/metadata.json" "$EXT_DIR/metadata.json"
install -o root -g root -m 0644 "$ROOT/packaging/gnome-shell-extension/extension.js" "$EXT_DIR/extension.js"
install -o root -g root -m 0644 "$ROOT/packaging/milmit-surfshark-watchdog.service" /etc/systemd/system/milmit-surfshark-watchdog.service

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable --now milmit-surfshark-watchdog.service >/dev/null 2>&1 || true
systemctl try-reload-or-restart polkit.service >/dev/null 2>&1 || true

echo "MilMit Surfshark privileged helper, advanced router engine, control center, auth-fixed connector, watchdog, hotspot manager and GNOME indicator installed."
command -v ipset >/dev/null 2>&1 && echo "Iran Direct: ipset ready." || echo "Iran Direct: ipset missing."
command -v tc >/dev/null 2>&1 && echo "Per-device speed limits: tc ready." || echo "Per-device speed limits: tc unavailable."
command -v conntrack >/dev/null 2>&1 && echo "Hotspot connection reset/repair: conntrack ready." || true
if systemctl is-active --quiet milmit-surfshark-watchdog.service 2>/dev/null; then echo "Watchdog: active · recovery + telemetry + quota enforcement enabled."; fi
echo "Advanced features: Hotspot VPN repair, per-device VPN/Direct/Block/Pause, quota/throttle, speed limits, Guest Hotspot, Force DNS, QUIC block, client isolation, IPv6 policy, manual domain/IP policies, Iran Direct, route tester, health, LKG and Emergency Stop."
echo "Future privileged operations from an active local session should not ask for the Ubuntu password again."
