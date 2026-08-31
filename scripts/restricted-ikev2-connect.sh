#!/usr/bin/env bash
set -euo pipefail

# Direct strongSwan backend modeled on Surfshark Android's IKEv2 handshake.
# Usage (root): restricted-ikev2-connect.sh <server-ip> <service-user>
# Password is read from stdin. An empty stdin reuses the root-only saved secret.

SERVER_IP="${1:-}"
SERVICE_USER="${2:-}"
CONF=/etc/swanctl/conf.d/milmit-surfshark-restricted.conf
CONN_NAME=milmit-surfshark-restricted
CHILD_NAME=milmit-restricted
STATE_DIR=/run/milmit-surfshark
STATE_FILE="$STATE_DIR/restricted.state"
CRED_DIR=/etc/milmit-surfshark
CRED_FILE="$CRED_DIR/credentials"
MSS=1200

if [[ $EUID -ne 0 ]]; then
  echo "This helper must run as root." >&2
  exit 77
fi
if [[ -z "$SERVER_IP" || -z "$SERVICE_USER" ]]; then
  echo "usage: $0 <server-ip> <service-user>" >&2
  exit 64
fi
if ! [[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "server must be an IPv4 address" >&2
  exit 65
fi

SERVICE_PASS=""
IFS= read -r SERVICE_PASS || true

install -d -m 0700 "$CRED_DIR"
if [[ -n "$SERVICE_PASS" ]]; then
  umask 077
  printf 'SERVICE_USER=%q\nSERVICE_PASS=%q\n' "$SERVICE_USER" "$SERVICE_PASS" > "$CRED_FILE"
elif [[ -f "$CRED_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CRED_FILE"
  if [[ -z "${SERVICE_PASS:-}" ]]; then
    echo "Saved Surfshark password is empty." >&2
    exit 66
  fi
else
  echo "Surfshark service password is required for first restricted-mode setup." >&2
  exit 66
fi

if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE" || true
  if [[ -n "${VIRTUAL_IP:-}" ]]; then
    iptables -t mangle -D OUTPUT -s "$VIRTUAL_IP/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "${MSS_VALUE:-1200}" 2>/dev/null || true
  fi
  if [[ -n "${IFACE:-}" ]] && command -v resolvectl >/dev/null 2>&1; then
    resolvectl revert "$IFACE" 2>/dev/null || true
  fi
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

swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true
swanctl --terminate --ike surfshark-tr >/dev/null 2>&1 || true
swanctl --load-conns
swanctl --load-creds
swanctl --initiate --child "$CHILD_NAME"

SA_TEXT="$(swanctl --list-sas 2>&1 || true)"
VIRTUAL_IP="$(printf '%s\n' "$SA_TEXT" | sed -nE "s/.*local  '[^']+' @ .*[[]([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)[]].*/\1/p" | head -n1)"
if [[ -z "$VIRTUAL_IP" ]]; then
  VIRTUAL_IP="$(printf '%s\n' "$SA_TEXT" | sed -nE 's/.*local  ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\/32.*/\1/p' | head -n1)"
fi
if [[ -z "$VIRTUAL_IP" ]]; then
  echo "$SA_TEXT"
  echo "Tunnel established but virtual IPv4 could not be detected." >&2
  exit 67
fi

IFACE="$(ip route get "$SERVER_IP" | sed -nE 's/.* dev ([^ ]+).*/\1/p' | head -n1)"
if [[ -z "$IFACE" ]]; then
  IFACE="$(ip -4 route show default | awk 'NR==1 {print $5}')"
fi

iptables -t mangle -D OUTPUT -s "$VIRTUAL_IP/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS" 2>/dev/null || true
iptables -t mangle -A OUTPUT -s "$VIRTUAL_IP/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS"

if command -v resolvectl >/dev/null 2>&1 && [[ -n "$IFACE" ]]; then
  resolvectl dns "$IFACE" 162.252.172.57 149.154.159.92 || true
  resolvectl domain "$IFACE" '~.' || true
  resolvectl flush-caches || true
fi

install -d -m 0755 "$STATE_DIR"
cat > "$STATE_FILE" <<EOF
VIRTUAL_IP=$VIRTUAL_IP
IFACE=$IFACE
MSS_VALUE=$MSS
SERVER_IP=$SERVER_IP
EOF
chmod 0644 "$STATE_FILE"

TRACE="$(curl -4 --interface "$VIRTUAL_IP" --max-time 10 -ks https://1.1.1.1/cdn-cgi/trace || true)"
PUBLIC_IP="$(printf '%s\n' "$TRACE" | sed -n 's/^ip=//p' | head -n1)"
EXIT_COUNTRY="$(printf '%s\n' "$TRACE" | sed -n 's/^loc=//p' | head -n1)"

printf '\nRestricted Surfshark IKEv2 is established\n'
printf 'Virtual IPv4 : %s\n' "$VIRTUAL_IP"
printf 'MSS clamp    : %s\n' "$MSS"
printf 'DNS          : 162.252.172.57, 149.154.159.92\n'
printf 'Interface    : %s\n' "$IFACE"
printf '%s\n' "$SA_TEXT"
if [[ -n "$PUBLIC_IP" ]]; then
  printf '\nData-path test: OK\nPublic IPv4 : %s\nExit country: %s\n' "$PUBLIC_IP" "${EXIT_COUNTRY:-unknown}"
else
  printf '\nData-path test: FAILED\n'
  exit 68
fi
