#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run this installer through pkexec." >&2; exit 77; fi

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
EXT_UUID=surfshark-ikev2@milmit.net
EXT_DIR="/usr/share/gnome-shell/extensions/$EXT_UUID"

# Iran Direct uses an efficient kernel IP set instead of thousands of ip rules.
if ! command -v ipset >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y ipset >/dev/null 2>&1 || true
fi

install -d -m 0755 /usr/lib/milmit-surfshark /usr/libexec /usr/share/polkit-1/actions "$EXT_DIR" /var/lib/milmit-surfshark
install -o root -g root -m 0755 "$ROOT/scripts/restricted-ikev2-connect.sh" /usr/lib/milmit-surfshark/restricted-ikev2-connect.sh
install -o root -g root -m 0755 "$ROOT/scripts/restricted-ikev2-disconnect.sh" /usr/lib/milmit-surfshark/restricted-ikev2-disconnect.sh
install -o root -g root -m 0755 "$ROOT/scripts/hotspot-device-policy.sh" /usr/lib/milmit-surfshark/hotspot-device-policy.sh
install -o root -g root -m 0755 "$ROOT/scripts/hotspot-device-manager.py" /usr/lib/milmit-surfshark/hotspot-device-manager.py
install -o root -g root -m 0755 "$ROOT/scripts/milmit-surfshark-watchdog.sh" /usr/lib/milmit-surfshark/milmit-surfshark-watchdog.sh
install -o root -g root -m 0755 "$ROOT/scripts/milmit-surfshark-helper" /usr/libexec/milmit-surfshark-helper
install -o root -g root -m 0644 "$ROOT/packaging/net.milmit.surfshark-ikev2.policy" /usr/share/polkit-1/actions/net.milmit.surfshark-ikev2.policy
install -o root -g root -m 0644 "$ROOT/packaging/gnome-shell-extension/metadata.json" "$EXT_DIR/metadata.json"
install -o root -g root -m 0644 "$ROOT/packaging/gnome-shell-extension/extension.js" "$EXT_DIR/extension.js"
install -o root -g root -m 0644 "$ROOT/packaging/milmit-surfshark-watchdog.service" /etc/systemd/system/milmit-surfshark-watchdog.service

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable --now milmit-surfshark-watchdog.service >/dev/null 2>&1 || true
systemctl try-reload-or-restart polkit.service >/dev/null 2>&1 || true

echo "MilMit Surfshark privileged helper, watchdog, hotspot device manager and GNOME VPN indicator installed."
if command -v ipset >/dev/null 2>&1; then
  echo "Iran Direct dependency: ipset ready."
else
  echo "Iran Direct dependency: ipset not installed; VPN Everything remains available."
fi
if systemctl is-active --quiet milmit-surfshark-watchdog.service 2>/dev/null; then
  echo "Watchdog: active · live RX/TX/latency + auto recovery enabled."
else
  echo "Watchdog: installed but not active; check systemctl status milmit-surfshark-watchdog.service."
fi
echo "Future Connect/Disconnect/device-policy operations from an active local session should not ask for the Ubuntu password again."
