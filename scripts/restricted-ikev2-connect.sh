#!/usr/bin/env bash
set -euo pipefail

# Direct strongSwan backend modeled on Surfshark Android's IKEv2 handshake.
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

if [[ $EUID -ne 0 ]]; then echo "This helper must run as root." >&2; exit 77; fi
if [[ -z "$SERVER_IP" || -z "$SERVICE_USER" ]]; then echo "usage: $0 <server-ip> <service-user> [password-file]" >&2; exit 64; fi
if ! [[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then echo "server must be an IPv4 address" >&2; exit 65; fi

SERVICE_PASS=""
if [[ -n "$PASSWORD_FILE" ]]; then
  [[ -f "$PASSWORD_FILE" ]] || { echo "Password handoff file does not exist: $PASSWORD_FILE" >&2; exit 66; }
  SERVICE_PASS="$(cat -- "$PASSWORD_FILE")"
  rm -f -- "$PASSWORD_FILE" || true
elif [[ ! -t 0 ]]; then
  IFS= read -r SERVICE_PASS || true
fi

install -d -m 0700 "$CRED_DIR"
if [[ -n "$SERVICE_PASS" ]]; then
  umask 077
  printf 'SERVICE_USER=%q\nSERVICE_PASS=%q\n' "$SERVICE_USER" "$SERVICE_PASS" > "$CRED_FILE"
elif [[ -f "$CRED_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CRED_FILE"
  [[ -n "${SERVICE_PASS:-}" ]] || { echo "Saved Surfshark password is empty." >&2; exit 66; }
else
  echo "Surfshark service password is required for first restricted-mode setup." >&2
  exit 66
fi

# Clear previous temporary network state before a new attempt.
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE" || true
  [[ -z "${VIRTUAL_IP:-}" ]] || iptables -t mangle -D OUTPUT -s "$VIRTUAL_IP/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "${MSS_VALUE:-1200}" 2>/dev/null || true
  if [[ -n "${HOTSPOT_IFACE:-}" && -n "${HOTSPOT_SUBNET:-}" && -n "${VIRTUAL_IP:-}" ]]; then
    iptables -t nat -D POSTROUTING -s "$HOTSPOT_SUBNET" -j SNAT --to-source "$VIRTUAL_IP" 2>/dev/null || true
    iptables -t mangle -D FORWARD -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "${MSS_VALUE:-1200}" 2>/dev/null || true
    iptables -D FORWARD -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o "$HOTSPOT_IFACE" -d "$HOTSPOT_SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  fi
  [[ -z "${IFACE:-}" ]] || resolvectl revert "$IFACE" 2>/dev/null || true
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
        local { auth = eap-mschapv2; eap_id = $SERVICE_USER; id = $SERVICE_USER }
        remote { auth = pubkey; id = $SERVER_IP }
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
secrets { eap-milmit-surfshark { id = $SERVICE_USER; secret = "$SERVICE_PASS" } }
EOF
chmod 0600 "$CONF"

swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true
swanctl --terminate --ike surfshark-tr >/dev/null 2>&1 || true
swanctl --load-conns
swanctl --load-creds
swanctl --initiate --child "$CHILD_NAME"

SA_TEXT="$(swanctl --list-sas 2>&1 || true)"
VIRTUAL_IP="$(printf '%s\n' "$SA_TEXT" | sed -nE 's/.*local .*\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\].*/\1/p' | head -n1)"
[[ -n "$VIRTUAL_IP" ]] || { echo "$SA_TEXT"; echo "Restricted tunnel established but no virtual IPv4 was found." >&2; exit 67; }
IFACE="$(ip -4 route get "$SERVER_IP" 2>/dev/null | sed -nE 's/.* dev ([^ ]+).*/\1/p' | head -n1)"

iptables -t mangle -D OUTPUT -s "$VIRTUAL_IP/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS" 2>/dev/null || true
iptables -t mangle -A OUTPUT -s "$VIRTUAL_IP/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS"

if command -v resolvectl >/dev/null 2>&1 && [[ -n "$IFACE" ]]; then
  resolvectl dns "$IFACE" 162.252.172.57 149.154.159.92 || true
  resolvectl domain "$IFACE" '~.' || true
  resolvectl flush-caches || true
fi

# Detect an active NetworkManager shared connection (Ubuntu Hotspot/Ethernet sharing)
# and NAT clients to the Surfshark virtual IP so forwarded traffic matches the IPsec SA.
HOTSPOT_IFACE=""
HOTSPOT_SUBNET=""
while IFS=: read -r ACTIVE_NAME ACTIVE_DEVICE; do
  [[ -n "$ACTIVE_NAME" && -n "$ACTIVE_DEVICE" && "$ACTIVE_DEVICE" != "--" ]] || continue
  METHOD="$(nmcli -g ipv4.method connection show "$ACTIVE_NAME" 2>/dev/null | head -n1 || true)"
  [[ "$METHOD" == "shared" ]] || continue
  CIDR="$(ip -4 -o addr show dev "$ACTIVE_DEVICE" scope global 2>/dev/null | awk '{print $4}' | head -n1)"
  [[ -n "$CIDR" ]] || continue
  HOTSPOT_IFACE="$ACTIVE_DEVICE"
  HOTSPOT_SUBNET="$(python3 - "$CIDR" <<'PY'
import ipaddress, sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY
)"
  break
done < <(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null || true)

if [[ -n "$HOTSPOT_IFACE" && -n "$HOTSPOT_SUBNET" ]]; then
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  iptables -t nat -D POSTROUTING -s "$HOTSPOT_SUBNET" -j SNAT --to-source "$VIRTUAL_IP" 2>/dev/null || true
  iptables -t nat -A POSTROUTING -s "$HOTSPOT_SUBNET" -j SNAT --to-source "$VIRTUAL_IP"
  iptables -t mangle -D FORWARD -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS" 2>/dev/null || true
  iptables -t mangle -A FORWARD -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS"
  iptables -C FORWARD -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -j ACCEPT
  iptables -C FORWARD -o "$HOTSPOT_IFACE" -d "$HOTSPOT_SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -o "$HOTSPOT_IFACE" -d "$HOTSPOT_SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
fi

TRACE="$(curl -4 --interface "$VIRTUAL_IP" --max-time 10 -ks https://1.1.1.1/cdn-cgi/trace || true)"
PUBLIC_IP="$(printf '%s\n' "$TRACE" | sed -n 's/^ip=//p' | head -n1)"
EXIT_COUNTRY="$(printf '%s\n' "$TRACE" | sed -n 's/^loc=//p' | head -n1)"
[[ -n "$PUBLIC_IP" ]] || { printf '\nData-path test: FAILED\n'; exit 68; }

NM_MARKER_ACTIVE=0
if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager.service 2>/dev/null; then
  nmcli connection delete "$NM_MARKER" >/dev/null 2>&1 || true
  if nmcli connection add type dummy ifname "$NM_MARKER_IF" con-name "$NM_MARKER" ipv4.method disabled ipv6.method disabled connection.autoconnect no >/dev/null 2>&1; then
    nmcli connection up "$NM_MARKER" >/dev/null 2>&1 && NM_MARKER_ACTIVE=1 || true
  fi
fi

install -d -m 0755 "$STATE_DIR"
umask 077
cat > "$STATE_FILE" <<EOF
VIRTUAL_IP=$VIRTUAL_IP
IFACE=$IFACE
MSS_VALUE=$MSS
SERVER_IP=$SERVER_IP
PUBLIC_IP=$PUBLIC_IP
EXIT_COUNTRY=$EXIT_COUNTRY
NM_MARKER=$NM_MARKER
NM_MARKER_ACTIVE=$NM_MARKER_ACTIVE
HOTSPOT_IFACE=$HOTSPOT_IFACE
HOTSPOT_SUBNET=$HOTSPOT_SUBNET
EOF
chmod 0644 "$STATE_FILE"

printf '\nRestricted Surfshark IKEv2 is established\n'
printf 'Virtual IPv4 : %s\nMSS clamp    : %s\nDNS          : 162.252.172.57, 149.154.159.92\nInterface    : %s\n' "$VIRTUAL_IP" "$MSS" "$IFACE"
printf 'Ubuntu marker: %s\n' "$([[ "$NM_MARKER_ACTIVE" == 1 ]] && echo active || echo unavailable)"
if [[ -n "$HOTSPOT_IFACE" ]]; then printf 'Hotspot VPN   : ON · %s · %s\n' "$HOTSPOT_IFACE" "$HOTSPOT_SUBNET"; else printf 'Hotspot VPN   : no active shared connection detected\n'; fi
printf '%s\n' "$SA_TEXT"
printf '\nData-path test: OK\nPublic IPv4 : %s\nExit country: %s\n' "$PUBLIC_IP" "${EXIT_COUNTRY:-unknown}"
