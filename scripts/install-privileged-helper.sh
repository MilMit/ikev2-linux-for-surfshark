#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run this installer through pkexec." >&2
  exit 77
fi

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

install -d -m 0755 /usr/lib/milmit-surfshark /usr/libexec /usr/share/polkit-1/actions
install -o root -g root -m 0755 "$ROOT/scripts/restricted-ikev2-connect.sh" /usr/lib/milmit-surfshark/restricted-ikev2-connect.sh
install -o root -g root -m 0755 "$ROOT/scripts/restricted-ikev2-disconnect.sh" /usr/lib/milmit-surfshark/restricted-ikev2-disconnect.sh
install -o root -g root -m 0755 "$ROOT/scripts/milmit-surfshark-helper" /usr/libexec/milmit-surfshark-helper
install -o root -g root -m 0644 "$ROOT/packaging/net.milmit.surfshark-ikev2.policy" /usr/share/polkit-1/actions/net.milmit.surfshark-ikev2.policy

# Reloading polkit is normally automatic when policy files change. Try a
# non-fatal reload for distributions that keep policy state cached.
systemctl try-reload-or-restart polkit.service >/dev/null 2>&1 || true

echo "MilMit Surfshark privileged helper installed."
echo "Future Connect/Disconnect operations from an active local session should not ask for the Ubuntu password again."
