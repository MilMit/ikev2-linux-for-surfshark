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
CONN_NAME=milmit-surfshark-restricted
CHILD_NAME=milmit-restricted

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
    $CONN_NAME {
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
            $CHILD_NAME {
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

# Remove both our previous restricted SA and the old hostname-based test SA.
# Leaving surfshark-tr in CONNECTING state creates noise and can interfere with
# route/MOBIKE diagnostics on poisoned DNS networks.
swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true
swanctl --terminate --ike surfshark-tr >/dev/null 2>&1 || true

swanctl --load-conns
swanctl --load-creds

# IMPORTANT: use a unique child name. The legacy Surfshark profile also has a
# child called "surfshark"; initiating that generic name can select the wrong
# connection and send traffic to the DNS-poisoned hostname.
swanctl --initiate --child "$CHILD_NAME"

echo
swanctl --list-sas
