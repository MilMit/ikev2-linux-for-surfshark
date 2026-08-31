#!/bin/sh
set -eu

CONF_DIR="/etc/strongswan.d"
CONF_FILE="$CONF_DIR/charon-nm-surfshark.conf"

mkdir -p "$CONF_DIR"
cat > "$CONF_FILE" <<'EOF'
# Installed by MilMit ikev2-linux-for-surfshark.
# Surfshark's IKEv2 gateway offers EAP-PEAP first, while the known-working
# manual Surfshark flow uses direct EAP-MSCHAPv2. NetworkManager's charon-nm
# otherwise accepts PEAP and then fails validating Surfshark's RADIUS TLS cert.
# Disabling PEAP for charon-nm makes it NAK PEAP and negotiate MSCHAPv2.
charon-nm {
    plugins {
        eap-peap {
            load = no
        }
    }
}
EOF

chmod 0644 "$CONF_FILE"

# charon-nm is D-Bus/NetworkManager activated. Stop the current instance so
# the next VPN activation reloads strongSwan configuration.
pkill -x charon-nm 2>/dev/null || true

echo "Installed Surfshark NetworkManager compatibility configuration: $CONF_FILE"
