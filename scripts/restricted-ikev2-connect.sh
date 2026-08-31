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
MSS_CHAIN=MILMIT_VPN_MSS
MSS_VALUE=1200
SURFSHARK_DNS_1=162.252.172.57
SURFSHARK_DNS_2=149.154.159.92

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
swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true
swanctl --terminate --ike surfshark-tr >/dev/null 2>&1 || true

swanctl --load-conns
swanctl --load-creds

# Use a unique child name so the legacy hostname profile can never be selected.
swanctl --initiate --child "$CHILD_NAME"

# Extract the assigned Surfshark virtual IPv4 from the established SA.
VIP="$(swanctl --list-sas 2>/dev/null | sed -nE 's/.*\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\].*/\1/p' | head -n1)"
if [[ -z "$VIP" ]]; then
  echo "ERROR: tunnel established but virtual IPv4 could not be detected" >&2
  exit 70
fi

# The restricted mobile path black-holes larger TCP packets. A 1200-byte MSS
# was verified to make TLS/HTTPS work over this IKEv2 tunnel. Keep the rule in a
# dedicated chain so reconnects replace it instead of accumulating duplicates.
iptables -t mangle -N "$MSS_CHAIN" 2>/dev/null || true
iptables -t mangle -F "$MSS_CHAIN"
iptables -t mangle -C OUTPUT -j "$MSS_CHAIN" 2>/dev/null || \
  iptables -t mangle -A OUTPUT -j "$MSS_CHAIN"
iptables -t mangle -A "$MSS_CHAIN" \
  -s "$VIP/32" -p tcp --tcp-flags SYN,RST SYN \
  -j TCPMSS --set-mss "$MSS_VALUE"

# strongSwan's resolvconf hook is not compatible with this Ubuntu setup, so
# install Surfshark DNS through systemd-resolved after the SA is established.
VPN_IFACE="$(ip -o -4 addr show | awk -v ip="$VIP" '$4 ~ ("^" ip "/") {print $2; exit}')"
if [[ -n "$VPN_IFACE" ]] && command -v resolvectl >/dev/null 2>&1; then
  resolvectl dns "$VPN_IFACE" "$SURFSHARK_DNS_1" "$SURFSHARK_DNS_2" || true
  resolvectl domain "$VPN_IFACE" '~.' || true
  resolvectl flush-caches || true
fi

echo
echo "Restricted Surfshark IKEv2 is established"
echo "Virtual IPv4 : $VIP"
echo "MSS clamp    : $MSS_VALUE"
echo "DNS          : $SURFSHARK_DNS_1, $SURFSHARK_DNS_2"
[[ -n "$VPN_IFACE" ]] && echo "Interface    : $VPN_IFACE"

echo
swanctl --list-sas

echo
# Verify data path without depending on DNS. Failure here should be visible but
# must not tear down an otherwise established tunnel.
TRACE="$(curl -4 --interface "$VIP" --max-time 10 -ks https://1.1.1.1/cdn-cgi/trace 2>/dev/null || true)"
PUBLIC_IP="$(printf '%s\n' "$TRACE" | sed -n 's/^ip=//p' | head -n1)"
LOCATION="$(printf '%s\n' "$TRACE" | sed -n 's/^loc=//p' | head -n1)"
if [[ -n "$PUBLIC_IP" ]]; then
  echo "Data-path test: OK"
  echo "Public IPv4 : $PUBLIC_IP"
  [[ -n "$LOCATION" ]] && echo "Exit country: $LOCATION"
else
  echo "Data-path test: FAILED (tunnel SA remains established)"
fi
