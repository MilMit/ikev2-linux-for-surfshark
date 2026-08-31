#!/usr/bin/env bash
set -euo pipefail

# Direct strongSwan backend modeled on Surfshark Android's IKEv2 handshake.
# Usage (root): restricted-ikev2-connect.sh <server-ip> <service-user> <service-password>
# The server is addressed and authenticated by IP because Surfshark's Android
# IKEv2 endpoint certificates are issued to the concrete server IP.

SERVER_IP="${1:-}"
SERVICE_USER="${2:-}"
SERVICE_PASS="${3:-}"
CONF=/etc/swanctl/conf.d/milmit-surfshark-restricted.conf

if [[ $EUID -ne 0 ]]; then
  echo "This helper must run as root." >&2
  exit 77
fi
if [[ -z "$SERVER_IP" || -z "$SERVICE_USER" || -z "$SERVICE_PASS" ]]; then
  echo "usage: $0 <server-ip> <service-user> <service-password>" >&2
  exit 64
fi
if ! [[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "server must be an IPv4 address" >&2
  exit 65
fi

install -d -m 0755 /etc/swanctl/conf.d
cat >"$CONF" <<EOF
connections {
    milmit-surfshark-restricted {
        version = 2
        remote_addrs = $SERVER_IP
        proposals = aes256gcm16-prfsha256-ecp521,aes256-sha256-modp2048
        encap = yes
        fragmentation = yes
        mobike = yes
        send_certreq = yes

        local {
            auth = eap-mschapv2
            eap_id = $SERVICE_USER
            id = $SERVICE_USER
        }

        remote {
            auth = pubkey
            id = $SERVER_IP
        }

        children {
            surfshark {
                local_ts = 0.0.0.0/0
                remote_ts = 0.0.0.0/0
                esp_proposals = aes256-sha1,aes256-sha256
                start_action = none
                dpd_action = restart
            }
        }

        vips = 0.0.0.0
        dpd_delay = 30s
    }
}

secrets {
    eap-milmit-surfshark {
        id = $SERVICE_USER
        secret = "$SERVICE_PASS"
    }
}
EOF
chmod 0600 "$CONF"

# Remove an old instance before loading the new endpoint.
swanctl --terminate --ike milmit-surfshark-restricted >/dev/null 2>&1 || true
swanctl --load-conns
swanctl --load-creds

# Android Surfshark sends PEAP NAK and then uses EAP-MSCHAPv2. The regular
# charon daemon is configured separately from charon-nm; if PEAP is installed,
# the connection's auth method still requires EAP-MSCHAPv2.
swanctl --initiate --child surfshark

echo
swanctl --list-sas
