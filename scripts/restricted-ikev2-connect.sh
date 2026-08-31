#!/usr/bin/env bash
set -euo pipefail

SERVER_IP="${1:-}"
SERVICE_USER="${2:-}"
MSS="${3:-1200}"
DNS_CSV="${4:-162.252.172.57,149.154.159.92}"
HOTSPOT_VPN="${5:-1}"
RECOVER_NETWORK="${6:-1}"
HOTSPOT_IFACE_REQUEST="${7:-auto}"

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
HOTSPOT_RULE_PREF=179
HOTSPOT_XFRM_PRIORITY=383614

if [[ $EUID -ne 0 ]]; then echo "This helper must run as root." >&2; exit 77; fi
if [[ -z "$SERVER_IP" || -z "$SERVICE_USER" ]]; then echo "usage: $0 <server-ip> <service-user> [mss] [dns-csv] [hotspot-vpn] [recover] [hotspot-iface|auto]" >&2; exit 64; fi
[[ "$MSS" =~ ^[0-9]+$ && "$MSS" -ge 900 && "$MSS" -le 1400 ]] || { echo "MSS must be 900-1400" >&2; exit 64; }
[[ "$HOTSPOT_VPN" == 0 || "$HOTSPOT_VPN" == 1 ]] || exit 64
[[ "$RECOVER_NETWORK" == 0 || "$RECOVER_NETWORK" == 1 ]] || exit 64
[[ "$HOTSPOT_IFACE_REQUEST" == auto || "$HOTSPOT_IFACE_REQUEST" =~ ^[a-zA-Z0-9_.:-]{1,32}$ ]] || { echo "invalid hotspot interface" >&2; exit 64; }

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

is_shared_iface() {
  local dev="$1" name method cidr
  ip link show dev "$dev" >/dev/null 2>&1 || return 1
  cidr="$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk '{print $4}' | head -n1)"
  [[ -n "$cidr" ]] || return 1
  if command -v nmcli >/dev/null 2>&1; then
    name="$(nmcli -g GENERAL.CONNECTION device show "$dev" 2>/dev/null | head -n1 || true)"
    if [[ -n "$name" && "$name" != -- ]]; then
      method="$(nmcli -g ipv4.method connection show "$name" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
      [[ "$method" == shared ]] && return 0
    fi
  fi
  [[ "$cidr" == 10.42.* ]]
}

detect_hotspot() {
  HOTSPOT_CONNECTION="" HOTSPOT_IFACE="" HOTSPOT_SUBNET=""
  local line name dev method cidr type state

  if [[ "$HOTSPOT_IFACE_REQUEST" != auto ]]; then
    if is_shared_iface "$HOTSPOT_IFACE_REQUEST"; then
      dev="$HOTSPOT_IFACE_REQUEST"
      cidr="$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk '{print $4}' | head -n1)"
      name="$(nmcli -g GENERAL.CONNECTION device show "$dev" 2>/dev/null | head -n1 || true)"
      HOTSPOT_CONNECTION="${name:-Hotspot}"
      HOTSPOT_IFACE="$dev"
      HOTSPOT_SUBNET="$(subnet_from_cidr "$cidr")"
      return 0
    fi
    echo "Selected hotspot interface '$HOTSPOT_IFACE_REQUEST' is not currently an active shared/hotspot interface." >&2
    return 0
  fi

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
  local subnet="${1:-}"
  [[ -n "$subnet" ]] || return 0
  command -v conntrack >/dev/null 2>&1 || return 0
  conntrack -D -s "$subnet" >/dev/null 2>&1 || true
  conntrack -D -d "$subnet" >/dev/null 2>&1 || true
}

remove_hotspot_policy() {
  local subnet="${1:-}"
  [[ -n "$subnet" ]] || return 0
  ip xfrm policy delete src "$subnet" dst 0.0.0.0/0 dir out priority "$HOTSPOT_XFRM_PRIORITY" if_id "$XFRM_IF_ID" >/dev/null 2>&1 || true
}

purge_hotspot_rules() {
  local vip="${1:-}" iface="${2:-}" subnet="${3:-}" old_mss="${4:-1200}" dns="${5:-}"
  [[ -n "$subnet" ]] || return 0
  remove_hotspot_policy "$subnet"
  while ip rule del pref "$HOTSPOT_RULE_PREF" from "$subnet" lookup "$ROUTE_TABLE" >/dev/null 2>&1; do :; done
  while IFS= read -r rule; do
    [[ "$rule" == *"-s $subnet"* && "$rule" == *"-j SNAT --to-source 10.6."* ]] || continue
    iptables -t nat -D POSTROUTING ${rule#-A POSTROUTING } >/dev/null 2>&1 || true
  done < <(iptables -t nat -S POSTROUTING 2>/dev/null || true)
  if [[ -n "$iface" ]]; then
    while iptables -t mangle -D FORWARD -i "$iface" -s "$subnet" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$old_mss" 2>/dev/null; do :; done
    while iptables -D FORWARD -i "$iface" -o "$XFRM_IF" -s "$subnet" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -i "$XFRM_IF" -o "$iface" -d "$subnet" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
    if [[ -n "$dns" ]]; then
      while iptables -t nat -D PREROUTING -i "$iface" -s "$subnet" -p udp --dport 53 -j DNAT --to-destination "$dns" 2>/dev/null; do :; done
      while iptables -t nat -D PREROUTING -i "$iface" -s "$subnet" -p tcp --dport 53 -j DNAT --to-destination "$dns" 2>/dev/null; do :; done
    fi
  fi
  flush_hotspot_conntrack "$subnet"
}

cleanup_old() {
  local vip iface old_mss hs_iface hs_subnet hs_dns server
  vip="$(state_get VIRTUAL_IP)"; iface="$(state_get IFACE)"; old_mss="$(state_get MSS_VALUE)"
  hs_iface="$(state_get HOTSPOT_IFACE)"; hs_subnet="$(state_get HOTSPOT_SUBNET)"; hs_dns="$(state_get HOTSPOT_DNS)"; server="$(state_get SERVER_IP)"
  [[ -z "$vip" ]] || iptables -t mangle -D OUTPUT -s "$vip/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "${old_mss:-1200}" 2>/dev/null || true
  purge_hotspot_rules "$vip" "$hs_iface" "$hs_subnet" "${old_mss:-1200}" "$hs_dns"
  [[ -z "$server" ]] || ip route del throw "$server" table "$ROUTE_TABLE" >/dev/null 2>&1 || true
  ip route del default dev "$XFRM_IF" table "$ROUTE_TABLE" >/dev/null 2>&1 || true
  ip link del "$XFRM_IF" >/dev/null 2>&1 || true
  if [[ -n "$iface" ]] && command -v resolvectl >/dev/null 2>&1; then resolvectl revert "$iface" >/dev/null 2>&1 || true; fi
  [[ -z "$vip" || -z "$iface" ]] || ip addr del "$vip/32" dev "$iface" >/dev/null 2>&1 || true
  rm -f "$STATE_FILE"
}

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

SERVICE_PASS=""
if [[ ! -t 0 ]]; then IFS= read -r SERVICE_PASS || true; fi
install -d -m 0700 "$CRED_DIR"
if [[ -n "$SERVICE_PASS" ]]; then
  umask 077
  printf 'SERVICE_USER=%q\nSERVICE_PASS=%q\n' "$SERVICE_USER" "$SERVICE_PASS" > "$CRED_FILE"
elif [[ -f "$CRED_FILE" ]]; then
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
  purge_hotspot_rules "" "$HOTSPOT_IFACE" "$HOTSPOT_SUBNET" "$MSS" "$HOTSPOT_DNS"
  if ! ip link add "$XFRM_IF" type xfrm if_id "$XFRM_IF_ID" 2>/dev/null; then echo "Kernel/iproute2 could not create XFRM interface $XFRM_IF." >&2; exit 70; fi
  ip link set "$XFRM_IF" mtu 1280 up
fi

ESC_PASS="${SERVICE_PASS//\\/\\\\}"
ESC_PASS="${ESC_PASS//\"/\\\"}"
IF_ID_LINES=""
if [[ "$ROUTE_BASED" == 1 ]]; then IF_ID_LINES="                if_id_in = $XFRM_IF_ID\n                if_id_out = $XFRM_IF_ID"; fi

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
        remote { auth = pubkey; id = %any }
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
secrets { eap-milmit-surfshark { id = $SERVICE_USER; secret = "$ESC_PASS" } }
EOF
chmod 0600 "$CONF"

swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true
swanctl --terminate --ike surfshark-tr >/dev/null 2>&1 || true
swanctl --load-conns
swanctl --load-creds
if ! swanctl --initiate --child "$CHILD_NAME"; then
  swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true
  ip link del "$XFRM_IF" >/dev/null 2>&1 || true
  exit 69
fi

SA_TEXT="$(swanctl --list-sas 2>&1 || true)"
VIRTUAL_IP="$(printf '%s\n' "$SA_TEXT" | sed -nE 's/.*local .*\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\].*/\1/p' | head -n1)"
[[ -n "$VIRTUAL_IP" ]] || { swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true; ip link del "$XFRM_IF" >/dev/null 2>&1 || true; echo "$SA_TEXT"; echo "No virtual IPv4 was found." >&2; exit 67; }
IFACE="$(ip -4 route get "$SERVER_IP" 2>/dev/null | sed -nE 's/.* dev ([^ ]+).*/\1/p' | head -n1)"

iptables -t mangle -D OUTPUT -s "$VIRTUAL_IP/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS" 2>/dev/null || true
iptables -t mangle -A OUTPUT -s "$VIRTUAL_IP/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS"

if command -v resolvectl >/dev/null 2>&1 && [[ -n "$IFACE" ]]; then
  resolvectl dns "$IFACE" "${VALID_DNS[@]}" || true
  resolvectl domain "$IFACE" '~.' || true
  resolvectl flush-caches || true
fi

HOTSPOT_XFRM_POLICY=0
HOTSPOT_XFRM_SPI=""
if [[ "$ROUTE_BASED" == 1 ]]; then
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  ip route replace throw "$SERVER_IP" table "$ROUTE_TABLE"
  ip route replace default dev "$XFRM_IF" src "$VIRTUAL_IP" table "$ROUTE_TABLE"
  while ip rule del pref "$HOTSPOT_RULE_PREF" from "$HOTSPOT_SUBNET" lookup "$ROUTE_TABLE" >/dev/null 2>&1; do :; done
  ip rule add pref "$HOTSPOT_RULE_PREF" from "$HOTSPOT_SUBNET" lookup "$ROUTE_TABLE"
  read -r OUTER_SRC OUTER_DST OUT_SPI OUT_REQID <<< "$(ip xfrm state | awk '/^src / {s=$2; d=$4; spi=""; req=""} /^[[:space:]]+proto esp/ {for (i=1;i<=NF;i++) {if ($i=="spi") spi=$(i+1); if ($i=="reqid") req=$(i+1)}} /^[[:space:]]+dir out/ {print s, d, spi, req; exit}')"
  purge_hotspot_rules "$VIRTUAL_IP" "$HOTSPOT_IFACE" "$HOTSPOT_SUBNET" "$MSS" "$HOTSPOT_DNS"
  if [[ -n "${OUTER_SRC:-}" && -n "${OUTER_DST:-}" && -n "${OUT_SPI:-}" && -n "${OUT_REQID:-}" ]]; then
    if ip xfrm policy add src "$HOTSPOT_SUBNET" dst 0.0.0.0/0 dir out priority "$HOTSPOT_XFRM_PRIORITY" if_id "$XFRM_IF_ID" tmpl src "$OUTER_SRC" dst "$OUTER_DST" proto esp spi "$OUT_SPI" reqid "$OUT_REQID" mode tunnel; then
      HOTSPOT_XFRM_POLICY=1; HOTSPOT_XFRM_SPI="$OUT_SPI"
    fi
  fi
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
  purge_hotspot_rules "$VIRTUAL_IP" "$HOTSPOT_IFACE" "$HOTSPOT_SUBNET" "$MSS" "$HOTSPOT_DNS"
  ip route del throw "$SERVER_IP" table "$ROUTE_TABLE" >/dev/null 2>&1 || true
  ip route del default dev "$XFRM_IF" table "$ROUTE_TABLE" >/dev/null 2>&1 || true
  ip link del "$XFRM_IF" >/dev/null 2>&1 || true
  [[ "$RECOVER_NETWORK" == 1 ]] && recover_interface "$IFACE" 1
  printf '\nData-path test: FAILED\n'; exit 68
fi

NM_MARKER_ACTIVE=0
if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager.service 2>/dev/null; then
  nmcli connection delete "$NM_MARKER" >/dev/null 2>&1 || true
  if nmcli connection add type dummy ifname "$NM_MARKER_IF" con-name "$NM_MARKER" ipv4.method disabled ipv6.method disabled connection.autoconnect no >/dev/null 2>&1; then nmcli connection up "$NM_MARKER" >/dev/null 2>&1 && NM_MARKER_ACTIVE=1 || true; fi
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
HOTSPOT_IFACE_REQUEST=$HOTSPOT_IFACE_REQUEST
HOTSPOT_CONNECTION=$HOTSPOT_CONNECTION
HOTSPOT_IFACE=$HOTSPOT_IFACE
HOTSPOT_SUBNET=$HOTSPOT_SUBNET
HOTSPOT_DNS=$HOTSPOT_DNS
HOTSPOT_XFRM_POLICY=$HOTSPOT_XFRM_POLICY
HOTSPOT_XFRM_SPI=$HOTSPOT_XFRM_SPI
ROUTE_BASED=$ROUTE_BASED
RECOVER_NETWORK=$RECOVER_NETWORK
EOF
chmod 0644 "$STATE_FILE"

printf '\nRestricted Surfshark IKEv2 is established\n'
printf 'Virtual IPv4 : %s\nMSS clamp    : %s\nDNS          : %s\nInterface    : %s\n' "$VIRTUAL_IP" "$MSS" "$DNS_CSV" "$IFACE"
printf 'Ubuntu marker: %s\n' "$([[ "$NM_MARKER_ACTIVE" == 1 ]] && echo active || echo unavailable)"
printf 'Hotspot target: %s\n' "$HOTSPOT_IFACE_REQUEST"
if [[ "$ROUTE_BASED" == 1 ]]; then
  printf 'Hotspot VPN   : ON · %s · %s\n' "$HOTSPOT_IFACE" "$HOTSPOT_SUBNET"
elif [[ "$HOTSPOT_VPN" == 1 ]]; then
  printf 'Hotspot VPN   : enabled · selected/auto hotspot not active\n'
else
  printf 'Hotspot VPN   : OFF · hotspot keeps normal route\n'
fi
printf '%s\n' "$SA_TEXT"
printf '\nData-path test: OK\nPublic IPv4 : %s\nExit country: %s\n' "$PUBLIC_IP" "${EXIT_COUNTRY:-unknown}"
