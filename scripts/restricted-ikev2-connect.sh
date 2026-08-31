#!/usr/bin/env bash
set -euo pipefail

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
NM_MARKER_IF=milmitvpn0
XFRM_IF=milmitxfrm0
XFRM_IF_ID=42
ROUTE_TABLE=220
# Must run before strongSwan's catch-all rule at priority 220.
HOTSPOT_RULE_PREF=179

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

subnet_from_cidr() {
  python3 - "$1" <<'PY'
import ipaddress, sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY
}

detect_hotspot() {
  HOTSPOT_CONNECTION="" HOTSPOT_IFACE="" HOTSPOT_SUBNET=""
  local line name dev method cidr type state
  if command -v nmcli >/dev/null 2>&1; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      dev="${line##*:}"; name="${line%:*}"
      [[ -n "$name" && -n "$dev" && "$dev" != "--" ]] || continue
      method="$(nmcli -g ipv4.method connection show "$name" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
      [[ "$method" == shared ]] || continue
      cidr="$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk '{print $4}' | head -n1)"
      [[ -n "$cidr" ]] || continue
      HOTSPOT_CONNECTION="$name"; HOTSPOT_IFACE="$dev"; HOTSPOT_SUBNET="$(subnet_from_cidr "$cidr")"; return 0
    done < <(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null || true)

    while IFS=: read -r dev type state; do
      [[ "$type" == wifi && "$state" == connected ]] || continue
      cidr="$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk '{print $4}' | head -n1)"
      [[ "$cidr" == 10.42.* ]] || continue
      name="$(nmcli -g GENERAL.CONNECTION device show "$dev" 2>/dev/null | head -n1 || true)"
      HOTSPOT_CONNECTION="${name:-Hotspot}"; HOTSPOT_IFACE="$dev"; HOTSPOT_SUBNET="$(subnet_from_cidr "$cidr")"; return 0
    done < <(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null || true)
  fi

  while read -r dev cidr; do
    [[ "$cidr" == 10.42.* ]] || continue
    HOTSPOT_CONNECTION=Hotspot; HOTSPOT_IFACE="$dev"; HOTSPOT_SUBNET="$(subnet_from_cidr "$cidr")"; return 0
  done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2, $4}')
}

flush_hotspot_conntrack() {
  local hs_subnet="${1:-}"
  [[ -n "$hs_subnet" ]] || return 0
  if command -v conntrack >/dev/null 2>&1; then
    conntrack -D -s "$hs_subnet" >/dev/null 2>&1 || true
    conntrack -D -d "$hs_subnet" >/dev/null 2>&1 || true
  fi
}

purge_legacy_hotspot_rules() {
  local hs_iface="${1:-}" hs_subnet="${2:-}"
  [[ -n "$hs_subnet" ]] || return 0

  # Remove MilMit SNAT rules left by pre-XFRM builds. Keep NetworkManager's
  # own nm-shared MASQUERADE rule untouched.
  while IFS= read -r rule; do
    [[ "$rule" == *"-s $hs_subnet"* && "$rule" == *"-j SNAT --to-source 10.6."* ]] || continue
    # shellcheck disable=SC2086
    iptables -t nat -D POSTROUTING ${rule#-A POSTROUTING } >/dev/null 2>&1 || true
  done < <(iptables -t nat -S POSTROUTING 2>/dev/null || true)

  if [[ -n "$hs_iface" ]]; then
    while iptables -D FORWARD -i "$hs_iface" -s "$hs_subnet" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -o "$hs_iface" -d "$hs_subnet" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
  fi
}

remove_hotspot_rules() {
  local vip="${1:-}" hs_iface="${2:-}" hs_subnet="${3:-}" old_mss="${4:-1200}" hs_dns="${5:-}"
  [[ -n "$hs_subnet" ]] || return 0
  while ip rule del pref "$HOTSPOT_RULE_PREF" from "$hs_subnet" lookup "$ROUTE_TABLE" >/dev/null 2>&1; do :; done
  [[ -z "$vip" ]] || while iptables -t nat -D POSTROUTING -s "$hs_subnet" ! -d "$hs_subnet" -o "$XFRM_IF" -j SNAT --to-source "$vip" 2>/dev/null; do :; done
  if [[ -n "$hs_iface" ]]; then
    while iptables -t mangle -D FORWARD -i "$hs_iface" -s "$hs_subnet" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$old_mss" 2>/dev/null; do :; done
    while iptables -D FORWARD -i "$hs_iface" -o "$XFRM_IF" -s "$hs_subnet" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -i "$XFRM_IF" -o "$hs_iface" -d "$hs_subnet" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
    if [[ -n "$hs_dns" ]]; then
      while iptables -t nat -D PREROUTING -i "$hs_iface" -s "$hs_subnet" -p udp --dport 53 -j DNAT --to-destination "$hs_dns" 2>/dev/null; do :; done
      while iptables -t nat -D PREROUTING -i "$hs_iface" -s "$hs_subnet" -p tcp --dport 53 -j DNAT --to-destination "$hs_dns" 2>/dev/null; do :; done
    fi
  fi
  purge_legacy_hotspot_rules "$hs_iface" "$hs_subnet"
  flush_hotspot_conntrack "$hs_subnet"
}

remove_route_state() {
  local vip="${1:-}"
  ip route del throw "$SERVER_IP" table "$ROUTE_TABLE" >/dev/null 2>&1 || true
  ip route del default dev "$XFRM_IF" table "$ROUTE_TABLE" >/dev/null 2>&1 || true
  if [[ -n "$vip" ]]; then
    while IFS= read -r route; do
      [[ "$route" == *"src $vip"* ]] || continue
      # shellcheck disable=SC2086
      ip route del table "$ROUTE_TABLE" $route >/dev/null 2>&1 || true
    done < <(ip route show table "$ROUTE_TABLE" 2>/dev/null || true)
  fi
  ip route flush cache >/dev/null 2>&1 || true
}

remove_xfrm_interface() { ip link del "$XFRM_IF" >/dev/null 2>&1 || true; }

recover_interface() {
  local iface="${1:-}" enabled="${2:-0}"
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

cleanup_old() {
  local vip iface old_mss hs_iface hs_subnet hs_dns
  vip="$(state_get VIRTUAL_IP)"; iface="$(state_get IFACE)"; old_mss="$(state_get MSS_VALUE)"
  hs_iface="$(state_get HOTSPOT_IFACE)"; hs_subnet="$(state_get HOTSPOT_SUBNET)"; hs_dns="$(state_get HOTSPOT_DNS)"
  [[ -z "$vip" ]] || iptables -t mangle -D OUTPUT -s "$vip/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "${old_mss:-1200}" 2>/dev/null || true
  remove_hotspot_rules "$vip" "$hs_iface" "$hs_subnet" "${old_mss:-1200}" "$hs_dns"
  remove_route_state "$vip"
  remove_xfrm_interface
  if [[ -n "$iface" ]] && command -v resolvectl >/dev/null 2>&1; then resolvectl revert "$iface" >/dev/null 2>&1 || true; fi
  [[ -z "$vip" || -z "$iface" ]] || ip addr del "$vip/32" dev "$iface" >/dev/null 2>&1 || true
  rm -f "$STATE_FILE"
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

cleanup_old
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
HOTSPOT_DNS="${VALID_DNS[0]}"

detect_hotspot
ROUTE_BASED=0
if [[ "$HOTSPOT_VPN" == 1 && -n "$HOTSPOT_IFACE" && -n "$HOTSPOT_SUBNET" ]]; then
  ROUTE_BASED=1
  purge_legacy_hotspot_rules "$HOTSPOT_IFACE" "$HOTSPOT_SUBNET"
  flush_hotspot_conntrack "$HOTSPOT_SUBNET"
  if ! ip link add "$XFRM_IF" type xfrm if_id "$XFRM_IF_ID" 2>/dev/null; then
    echo "Kernel/iproute2 could not create XFRM interface $XFRM_IF." >&2
    exit 70
  fi
  ip link set "$XFRM_IF" mtu 1280 up
fi

ESC_PASS="${SERVICE_PASS//\\/\\\\}"
ESC_PASS="${ESC_PASS//\"/\\\"}"
IF_ID_LINES=""
if [[ "$ROUTE_BASED" == 1 ]]; then
  IF_ID_LINES="                if_id_in = $XFRM_IF_ID\n                if_id_out = $XFRM_IF_ID"
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
            id = %any
        }
        children {
            $CHILD_NAME {
                local_ts = 0.0.0.0/0
                remote_ts = 0.0.0.0/0
                esp_proposals = aes256-sha1,aes256-sha256
                start_action = none
                dpd_action = restart
$(printf '%b' "$IF_ID_LINES")
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
  remove_xfrm_interface
  exit 69
fi

SA_TEXT="$(swanctl --list-sas 2>&1 || true)"
VIRTUAL_IP="$(printf '%s\n' "$SA_TEXT" | sed -nE 's/.*local .*\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\].*/\1/p' | head -n1)"
[[ -n "$VIRTUAL_IP" ]] || { swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true; remove_xfrm_interface; echo "$SA_TEXT"; echo "No virtual IPv4 was found." >&2; exit 67; }
IFACE="$(ip -4 route get "$SERVER_IP" 2>/dev/null | sed -nE 's/.* dev ([^ ]+).*/\1/p' | head -n1)"

iptables -t mangle -D OUTPUT -s "$VIRTUAL_IP/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS" 2>/dev/null || true
iptables -t mangle -A OUTPUT -s "$VIRTUAL_IP/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS"

if command -v resolvectl >/dev/null 2>&1 && [[ -n "$IFACE" ]]; then
  resolvectl dns "$IFACE" "${VALID_DNS[@]}" || true
  resolvectl domain "$IFACE" '~.' || true
  resolvectl flush-caches || true
fi

if [[ "$ROUTE_BASED" == 1 ]]; then
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  ip route replace throw "$SERVER_IP" table "$ROUTE_TABLE"
  ip route replace default dev "$XFRM_IF" src "$VIRTUAL_IP" table "$ROUTE_TABLE"
  while ip rule del pref "$HOTSPOT_RULE_PREF" from "$HOTSPOT_SUBNET" lookup "$ROUTE_TABLE" >/dev/null 2>&1; do :; done
  ip rule add pref "$HOTSPOT_RULE_PREF" from "$HOTSPOT_SUBNET" lookup "$ROUTE_TABLE"

  remove_hotspot_rules "$VIRTUAL_IP" "$HOTSPOT_IFACE" "$HOTSPOT_SUBNET" "$MSS" "$HOTSPOT_DNS"
  iptables -t nat -I POSTROUTING 1 -s "$HOTSPOT_SUBNET" ! -d "$HOTSPOT_SUBNET" -o "$XFRM_IF" -j SNAT --to-source "$VIRTUAL_IP"
  iptables -t mangle -I FORWARD 1 -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS"
  iptables -I FORWARD 1 -i "$HOTSPOT_IFACE" -o "$XFRM_IF" -s "$HOTSPOT_SUBNET" -j ACCEPT
  iptables -I FORWARD 1 -i "$XFRM_IF" -o "$HOTSPOT_IFACE" -d "$HOTSPOT_SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -t nat -I PREROUTING 1 -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -p udp --dport 53 -j DNAT --to-destination "$HOTSPOT_DNS"
  iptables -t nat -I PREROUTING 1 -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -p tcp --dport 53 -j DNAT --to-destination "$HOTSPOT_DNS"
  flush_hotspot_conntrack "$HOTSPOT_SUBNET"
  ip route flush cache >/dev/null 2>&1 || true
fi

TRACE="$(curl -4 --interface "$VIRTUAL_IP" --max-time 10 -ks https://1.1.1.1/cdn-cgi/trace || true)"
PUBLIC_IP="$(printf '%s\n' "$TRACE" | sed -n 's/^ip=//p' | head -n1)"
EXIT_COUNTRY="$(printf '%s\n' "$TRACE" | sed -n 's/^loc=//p' | head -n1)"
if [[ -z "$PUBLIC_IP" ]]; then
  swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true
  remove_hotspot_rules "$VIRTUAL_IP" "$HOTSPOT_IFACE" "$HOTSPOT_SUBNET" "$MSS" "$HOTSPOT_DNS"
  remove_route_state "$VIRTUAL_IP"
  remove_xfrm_interface
  [[ "$RECOVER_NETWORK" == 1 ]] && recover_interface "$IFACE" 1
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
HOTSPOT_CONNECTION=$HOTSPOT_CONNECTION
HOTSPOT_IFACE=$HOTSPOT_IFACE
HOTSPOT_SUBNET=$HOTSPOT_SUBNET
HOTSPOT_DNS=$HOTSPOT_DNS
HOTSPOT_RULE_PREF=$HOTSPOT_RULE_PREF
ROUTE_BASED=$ROUTE_BASED
XFRM_IF=$([[ "$ROUTE_BASED" == 1 ]] && echo "$XFRM_IF" || true)
XFRM_IF_ID=$([[ "$ROUTE_BASED" == 1 ]] && echo "$XFRM_IF_ID" || true)
RECOVER_NETWORK=$RECOVER_NETWORK
EOF
chmod 0644 "$STATE_FILE"

printf '\nRestricted Surfshark IKEv2 is established\n'
printf 'Virtual IPv4 : %s\nMSS clamp    : %s\nDNS          : %s\nInterface    : %s\n' "$VIRTUAL_IP" "$MSS" "$DNS_CSV" "$IFACE"
printf 'Ubuntu marker: %s\n' "$([[ "$NM_MARKER_ACTIVE" == 1 ]] && echo active || echo unavailable)"
if [[ "$ROUTE_BASED" == 1 ]]; then
  printf 'Hotspot VPN   : ON · route-based XFRM · %s · %s\n' "$HOTSPOT_IFACE" "$HOTSPOT_SUBNET"
  printf 'XFRM interface: %s · if_id %s · MTU 1280\n' "$XFRM_IF" "$XFRM_IF_ID"
elif [[ "$HOTSPOT_VPN" == 1 ]]; then
  printf 'Hotspot VPN   : enabled · no hotspot interface detected\n'
else
  printf 'Hotspot VPN   : OFF · hotspot keeps its normal route\n'
fi
printf '%s\n' "$SA_TEXT"
printf '\nData-path test: OK\nPublic IPv4 : %s\nExit country: %s\n' "$PUBLIC_IP" "${EXIT_COUNTRY:-unknown}"
