#!/usr/bin/env bash
set -euo pipefail

# Direct strongSwan backend modeled on Surfshark Android's IKEv2 handshake.
# Usage (root): restricted-ikev2-connect.sh <server-ip> <service-user> [password-file]
# Preferred GUI handoff is a short-lived 0600 password file. For compatibility
# with older GUI builds, stdin is also accepted when no password-file is passed.
# If neither provides a password, the root-only saved credential is reused.

SERVER_IP="${1:-}"
SERVICE_USER="${2:-}"
PASSWORD_FILE="${3:-}"
CONF=/etc/swanctl/conf.d/milmit-surfshark-restricted.conf
CONN_NAME=milmit-surfshark-restricted
CHILD_NAME=milmit-restricted
STATE_DIR=/run/milmit-surfshark
STATE_FILE="$STATE_DIR/restricted.state"
CRED_DIR=/etc/milmit-surfshark
CRED_FILE="$CRED_DIR/credentials"
MSS=1200
NM_MARKER="Surfshark IKEv2 (Connected)"
NM_MARKER_IF="milmitvpn0"

if [[ $EUID -ne 0 ]]; then
  echo "This helper must run as root." >&2
  exit 77
fi
if [[ -z "$SERVER_IP" || -z "$SERVICE_USER" ]]; then
  echo "usage: $0 <server-ip> <service-user> [password-file]" >&2
  exit 64
fi
if ! [[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "server must be an IPv4 address" >&2
  exit 65
fi

SERVICE_PASS=""
if [[ -n "$PASSWORD_FILE" ]]; then
  if [[ ! -f "$PASSWORD_FILE" ]]; then
    echo "Password handoff file does not exist: $PASSWORD_FILE" >&2
    exit 66
  fi
  SERVICE_PASS="$(cat -- "$PASSWORD_FILE")"
  rm -f -- "$PASSWORD_FILE" || true
else
  if [[ ! -t 0 ]]; then
    IFS= read -r SERVICE_PASS || true
  fi
fi

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

# Clear previous temporary network state before a new attempt.
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
if command -v nmcli >/dev/null 2>&1; then
  nmcli connection down "$NM_MARKER" >/dev/null 2>&1 || true
  nmcli connection delete "$NM_MARKER" >/dev/null 2>&1 || true
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
VIRTUAL_IP="$(printf '%s\n' "$SA_TEXT" | sed -nE 's/.*local .*\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\].*/\1/p' | head -n1)"
if [[ -z "$VIRTUAL_IP" ]]; then
  echo "$SA_TEXT"
  echo "Restricted tunnel established but no virtual IPv4 was found." >&2
  exit 67
fi

IFACE="$(ip -4 route get "$SERVER_IP" 2>/dev/null | sed -nE 's/.* dev ([^ ]+).*/\1/p' | head -n1)"

iptables -t mangle -D OUTPUT -s "$VIRTUAL_IP/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS" 2>/dev/null || true
iptables -t mangle -A OUTPUT -s "$VIRTUAL_IP/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS"

if command -v resolvectl >/dev/null 2>&1 && [[ -n "$IFACE" ]]; then
  resolvectl dns "$IFACE" 162.252.172.57 149.154.159.92 || true
  resolvectl domain "$IFACE" '~.' || true
  resolvectl flush-caches || true
fi

TRACE="$(curl -4 --interface "$VIRTUAL_IP" --max-time 10 -ks https://1.1.1.1/cdn-cgi/trace || true)"
PUBLIC_IP="$(printf '%s\n' "$TRACE" | sed -n 's/^ip=//p' | head -n1)"
EXIT_COUNTRY="$(printf '%s\n' "$TRACE" | sed -n 's/^loc=//p' | head -n1)"

if [[ -z "$PUBLIC_IP" ]]; then
  printf '\nData-path test: FAILED\n'
  exit 68
fi

# NetworkManager cannot own this tunnel because the working restricted backend
# is direct strongSwan. Create a harmless NetworkManager marker connection so
# Ubuntu/GNOME visibly shows an active Surfshark connection while the real
# traffic remains handled by strongSwan/XFRM. The marker carries no routes/DNS.
NM_MARKER_ACTIVE=0
if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager.service 2>/dev/null; then
  nmcli connection delete "$NM_MARKER" >/dev/null 2>&1 || true
  if nmcli connection add type dummy ifname "$NM_MARKER_IF" con-name "$NM_MARKER" \
      ipv4.method disabled ipv6.method disabled connection.autoconnect no >/dev/null 2>&1; then
    if nmcli connection up "$NM_MARKER" >/dev/null 2>&1; then
      NM_MARKER_ACTIVE=1
    fi
  fi
fi

install -d -m 0755 "$STATE_DIR"
umask 077
cat > "$STATE_FILE" <<EOF
VIRTUAL_IP=$VIRTUAL_IP
IFACE=$IFACE
MSS_VALUE=$MSS
SERVER_IP=$SERVER_IP
NM_MARKER=$NM_MARKER
NM_MARKER_ACTIVE=$NM_MARKER_ACTIVE
EOF

printf '\nRestricted Surfshark IKEv2 is established\n'
printf 'Virtual IPv4 : %s\n' "$VIRTUAL_IP"
printf 'MSS clamp    : %s\n' "$MSS"
printf 'DNS          : 162.252.172.57, 149.154.159.92\n'
printf 'Interface    : %s\n' "$IFACE"
printf 'Ubuntu marker: %s\n' "$([[ "$NM_MARKER_ACTIVE" == 1 ]] && echo active || echo unavailable)"
printf '%s\n' "$SA_TEXT"
printf '\nData-path test: OK\nPublic IPv4 : %s\nExit country: %s\n' "$PUBLIC_IP" "${EXIT_COUNTRY:-unknown}"
