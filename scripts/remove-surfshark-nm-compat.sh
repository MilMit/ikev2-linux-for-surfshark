#!/bin/sh
set -eu

CONF_FILE="/etc/strongswan.d/charon-nm-surfshark.conf"
rm -f "$CONF_FILE"
pkill -x charon-nm 2>/dev/null || true

echo "Removed Surfshark NetworkManager compatibility configuration."
