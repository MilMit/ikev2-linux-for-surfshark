#!/usr/bin/env bash
set -euo pipefail

# Direct strongSwan backend modeled on Surfshark Android's IKEv2 handshake.
SERVER_IP="${1:-}"
SERVICE_USER="${2:-}"
MSS="${3:-1200}"
DNS_CSV="${4:-162.252.172.57,149.154.159.92}"
HOTSPOT_VPN="${5:-1}"
RECOVER_NETWORK="${6:-1}"
CONF=/etc/swanctl/conf.d/milmit-surfshark-restricted.conf
CONN_NAME=milmit-surfshark-restricted
CHILD_NAME=milmit-restricted
STATE_DIR=/run/milmit-surfshark
STATE_FILE="$STATE_DIR/restricted.state"
CRED_DIR=/etc/milmit-surfshark
CRED_FILE="$CRED_DIR/credentials"
NM_MARKER="Surfshark IKEv2 (Connected)"
NM_MARKER_IF="milmitvpn0"

if [[ $EUID -ne 0 ]]; then echo "This helper must run as root." >&2; exit 77; fi
if [[ -z "$SERVER_IP" || -z "$SERVICE_USER" ]]; then echo "usage: $0 <server-ip> <service-user> [mss] [dns-csv] [hotspot-vpn] [recover]" >&2; exit 64; fi
[[ "$MSS" =~ ^[0-9]+$ && "$MSS" -ge 900 && "$MSS" -le 1400 ]] || { echo "MSS must be 900-1400" >&2; exit 64; }
[[ "$HOTSPOT_VPN" == 0 || "$HOTSPOT_VPN" == 1 ]] || exit 64
[[ "$RECOVER_NETWORK" == 0 || "$RECOVER_NETWORK" == 1 ]] || exit 64

state_get() {
  local key="$1"
  [[ -f "$STATE_FILE" ]] || return 0
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$STATE_FILE" 2>/dev/null || true
}

remove_route220_for_vip() {
  local vip="${1:-}"
  [[ -n "$vip" ]] || return 0
  while IFS= read -r route; do
    [[ "$route" == *"src $vip"* ]] || continue
    # shellcheck disable=SC2086
    ip route del table 220 $route >/dev/null 2>&1 || true
  done < <(ip route show table 220 2>/dev/null || true)
}

recover_interface() {
  local iface="${1:-}"
  local enabled="${2:-0}"
  [[ "$enabled" == 1 && -n "$iface" ]] || return 0
  command -v nmcli >/dev/null 2>&1 || return 0
  nmcli device reapply "$iface" >/dev/null 2>&1 || true
  command -v resolvectl >/dev/null 2>&1 && resolvectl flush-caches >/dev/null 2>&1 || true
  if ! curl -4 --interface "$iface" --max-time 4 -sS http://1.1.1.1/ >/dev/null 2>&1; then
    nmcli device disconnect "$iface" >/dev/null 2>&1 || true
    sleep 1
    nmcli device connect "$iface" >/dev/null 2>&1 || true
  fi
}

cleanup_values() {
  local vip="${1:-}" iface="${2:-}" old_mss="${3:-1200}" hs_iface="${4:-}" hs_subnet="${5:-}" recover="${6:-0}"
  if [[ -n "$vip" ]]; then
    iptables -t mangle -D OUTPUT -s "$vip/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$old_mss" 2>/dev/null || true
  fi
  if [[ -n "$hs_iface" && -n "$hs_subnet" && -n "$vip" ]]; then
    iptables -t nat -D POSTROUTING -s "$hs_subnet" -j SNAT --to-source "$vip" 2>/dev/null || true
    iptables -t mangle -D FORWARD -i "$hs_iface" -s "$hs_subnet" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$old_mss" 2>/dev/null || true
    iptables -D FORWARD -i "$hs_iface" -s "$hs_subnet" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o "$hs_iface" -d "$hs_subnet" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  fi
  if [[ -n "$iface" ]] && command -v resolvectl >/dev/null 2>&1; then
    resolvectl revert "$iface" >/dev/null 2>&1 || true
    resolvectl flush-caches >/dev/null 2>&1 || true
  fi
  remove_route220_for_vip "$vip"
  [[ -z "$vip" || -z "$iface" ]] || ip addr del "$vip/32" dev "$iface" >/dev/null 2>&1 || true
  recover_interface "$iface" "$recover"
}

SERVICE_PASS=""
if [[ ! -t 0 ]]; then IFS= read -r SERVICE_PASS || true; fi
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

# Remove stale state from a previous run. Do not recover the physical link here;
# this is a reconnect path, not a user-requested disconnect.
OLD_VIRTUAL_IP="$(state_get VIRTUAL_IP)"
OLD_IFACE="$(state_get IFACE)"
OLD_MSS="$(state_get MSS_VALUE)"
OLD_HOTSPOT_IFACE="$(state_get HOTSPOT_IFACE)"
OLD_HOTSPOT_SUBNET="$(state_get HOTSPOT_SUBNET)"
cleanup_values "$OLD_VIRTUAL_IP" "$OLD_IFACE" "${OLD_MSS:-1200}" "$OLD_HOTSPOT_IFACE" "$OLD_HOTSPOT_SUBNET" 0
rm -f "$STATE_FILE"

if command -v nmcli >/dev/null 2>&1; then
  nmcli connection down "$NM_MARKER" >/dev/null 2>&1 || true
  nmcli connection delete "$NM_MARKER" >/dev/null 2>&1 || true
fi

IFS=',' read -r -a DNS_SERVERS <<< "$DNS_CSV"
VALID_DNS=()
for dns in "${DNS_SERVERS[@]}"; do
  dns="${dns//[[:space:]]/}"
  [[ "$dns" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || continue
  VALID_DNS+=("$dns")
done
[[ ${#VALID_DNS[@]} -gt 0 ]] || VALID_DNS=(162.252.172.57 149.154.159.92)
DNS_CSV="$(IFS=,; echo "${VALID_DNS[*]}")"

ESC_PASS="${SERVICE_PASS//\\/\\\\}"
ESC_PASS="${ESC_PASS//\"/\\\"}"

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
            id = %any
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
        secret = "$ESC_PASS"
    }
}
EOF
chmod 0600 "$CONF"

swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true
swanctl --terminate --ike surfshark-tr >/dev/null 2>&1 || true
swanctl --load-conns
swanctl --load-creds
if ! swanctl --initiate --child "$CHILD_NAME"; then
  swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true
  exit 69
fi

SA_TEXT="$(swanctl --list-sas 2>&1 || true)"
VIRTUAL_IP="$(printf '%s\n' "$SA_TEXT" | sed -nE 's/.*local .*\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\].*/\1/p' | head -n1)"
[[ -n "$VIRTUAL_IP" ]] || { swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true; echo "$SA_TEXT"; echo "No virtual IPv4 was found." >&2; exit 67; }
IFACE="$(ip -4 route get "$SERVER_IP" 2>/dev/null | sed -nE 's/.* dev ([^ ]+).*/\1/p' | head -n1)"

iptables -t mangle -D OUTPUT -s "$VIRTUAL_IP/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS" 2>/dev/null || true
iptables -t mangle -A OUTPUT -s "$VIRTUAL_IP/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS"

if command -v resolvectl >/dev/null 2>&1 && [[ -n "$IFACE" ]]; then
  resolvectl dns "$IFACE" "${VALID_DNS[@]}" || true
  resolvectl domain "$IFACE" '~.' || true
  resolvectl flush-caches || true
fi

HOTSPOT_IFACE=""
HOTSPOT_SUBNET=""
if [[ "$HOTSPOT_VPN" == 1 ]] && command -v nmcli >/dev/null 2>&1; then
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
fi

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
if [[ -z "$PUBLIC_IP" ]]; then
  swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true
  cleanup_values "$VIRTUAL_IP" "$IFACE" "$MSS" "$HOTSPOT_IFACE" "$HOTSPOT_SUBNET" "$RECOVER_NETWORK"
  printf '\nData-path test: FAILED\n'
  exit 68
fi

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
DNS_CSV=$DNS_CSV
SERVER_IP=$SERVER_IP
NM_MARKER_ACTIVE=$NM_MARKER_ACTIVE
PUBLIC_IP=$PUBLIC_IP
EXIT_COUNTRY=$EXIT_COUNTRY
HOTSPOT_VPN=$HOTSPOT_VPN
HOTSPOT_IFACE=$HOTSPOT_IFACE
HOTSPOT_SUBNET=$HOTSPOT_SUBNET
RECOVER_NETWORK=$RECOVER_NETWORK
EOF
chmod 0644 "$STATE_FILE"

printf '\nRestricted Surfshark IKEv2 is established\n'
printf 'Virtual IPv4 : %s\nMSS clamp    : %s\nDNS          : %s\nInterface    : %s\n' "$VIRTUAL_IP" "$MSS" "$DNS_CSV" "$IFACE"
printf 'Ubuntu marker: %s\n' "$([[ "$NM_MARKER_ACTIVE" == 1 ]] && echo active || echo unavailable)"
if [[ "$HOTSPOT_VPN" == 1 ]]; then
  if [[ -n "$HOTSPOT_IFACE" ]]; then printf 'Hotspot VPN   : ON · %s · %s\n' "$HOTSPOT_IFACE" "$HOTSPOT_SUBNET"; else printf 'Hotspot VPN   : enabled · no active shared connection detected\n'; fi
else
  printf 'Hotspot VPN   : OFF · hotspot keeps its normal route\n'
fi
printf '%s\n' "$SA_TEXT"
printf '\nData-path test: OK\nPublic IPv4 : %s\nExit country: %s\n' "$PUBLIC_IP" "${EXIT_COUNTRY:-unknown}"
