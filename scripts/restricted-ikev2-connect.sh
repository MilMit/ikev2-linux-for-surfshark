#!/usr/bin/env bash
set -euo pipefail

SERVER_IP="${1:-}"
SERVICE_USER="${2:-}"
MSS="${3:-1200}"
DNS_CSV="${4:-162.252.172.57,149.154.159.92}"
HOTSPOT_VPN="${5:-1}"
RECOVER_NETWORK="${6:-1}"
HOTSPOT_IFACE_REQUEST="${7:-auto}"
KILL_SWITCH="${8:-0}"
ROUTING_MODE="${9:-vpn_all}"
HOTSPOT_VPN_MACS="${10:-}"
HOTSPOT_DIRECT_MACS="${11:-}"

CONF=/etc/swanctl/conf.d/milmit-surfshark-restricted.conf
CONN_NAME=milmit-surfshark-restricted
CHILD_NAME=milmit-restricted
STATE_DIR=/run/milmit-surfshark
STATE_FILE="$STATE_DIR/restricted.state"
CRED_DIR=/etc/milmit-surfshark
CRED_FILE="$CRED_DIR/credentials"
DATA_DIR=/var/lib/milmit-surfshark
IRAN_CACHE="$DATA_DIR/iran-ipv4.txt"
IRAN_SOURCE=https://raw.githubusercontent.com/ravenscourt/xylem-ip-db/main/lists/ir.ipv4.txt
IRAN_SET=MILMIT_IRAN
NM_MARKER="Surfshark IKEv2 (Connected)"
NM_MARKER_IF=milmitvpn0
XFRM_IF=milmitxfrm0
XFRM_IF_ID=42
ROUTE_TABLE=220
MARK_VPN=0x112
MARK_DIRECT=0x113
RULE_DIRECT_PREF=109
RULE_VPN_PREF=110
CHAIN_HOST=MILMIT_VPN_OUT
CHAIN_DNS=MILMIT_DNS_MARK
CHAIN_HOT=MILMIT_HOTSPOT_MARK
CHAIN_HOT_DNS=MILMIT_HOTSPOT_DNS
CHAIN_MSS=MILMIT_VPN_MSS
CHAIN_KILL=MILMIT_VPN_KILL

[[ $EUID -eq 0 ]] || { echo "This helper must run as root." >&2; exit 77; }
[[ -n "$SERVER_IP" && -n "$SERVICE_USER" ]] || { echo "usage: $0 <server-ip> <service-user> [mss] [dns-csv] [hotspot-vpn] [recover] [hotspot-iface|auto] [kill-switch] [vpn_all|iran_direct] [vpn-macs] [direct-macs]" >&2; exit 64; }
[[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "invalid server IPv4" >&2; exit 64; }
[[ "$MSS" =~ ^[0-9]+$ && "$MSS" -ge 900 && "$MSS" -le 1400 ]] || { echo "MSS must be 900-1400" >&2; exit 64; }
[[ "$HOTSPOT_VPN" == 0 || "$HOTSPOT_VPN" == 1 ]] || exit 64
[[ "$RECOVER_NETWORK" == 0 || "$RECOVER_NETWORK" == 1 ]] || exit 64
[[ "$KILL_SWITCH" == 0 || "$KILL_SWITCH" == 1 ]] || exit 64
[[ "$ROUTING_MODE" == vpn_all || "$ROUTING_MODE" == iran_direct ]] || { echo "invalid routing mode" >&2; exit 64; }
[[ "$HOTSPOT_IFACE_REQUEST" == auto || "$HOTSPOT_IFACE_REQUEST" =~ ^[a-zA-Z0-9_.:-]{1,32}$ ]] || { echo "invalid hotspot interface" >&2; exit 64; }
[[ -z "$HOTSPOT_VPN_MACS" || "$HOTSPOT_VPN_MACS" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}(,([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})*$ ]] || { echo "invalid hotspot VPN MAC list" >&2; exit 64; }
[[ -z "$HOTSPOT_DIRECT_MACS" || "$HOTSPOT_DIRECT_MACS" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}(,([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})*$ ]] || { echo "invalid hotspot Direct MAC list" >&2; exit 64; }

normalize_mac_csv() {
  local csv="$1" out="" mac
  IFS=',' read -r -a arr <<< "$csv"
  for mac in "${arr[@]:-}"; do
    [[ -n "$mac" ]] || continue
    mac="${mac^^}"
    if [[ -z "$out" ]]; then out="$mac"; elif [[ ",$out," != *",$mac,"* ]]; then out="$out,$mac"; fi
  done
  printf '%s' "$out"
}
HOTSPOT_VPN_MACS="$(normalize_mac_csv "$HOTSPOT_VPN_MACS")"
HOTSPOT_DIRECT_MACS="$(normalize_mac_csv "$HOTSPOT_DIRECT_MACS")"
if [[ -n "$HOTSPOT_VPN_MACS" && -n "$HOTSPOT_DIRECT_MACS" ]]; then
  IFS=',' read -r -a vpn_macs_check <<< "$HOTSPOT_VPN_MACS"
  for mac in "${vpn_macs_check[@]}"; do
    [[ ",$HOTSPOT_DIRECT_MACS," != *",$mac,"* ]] || { echo "MAC $mac cannot be both VPN and Direct." >&2; exit 64; }
  done
fi
VPN_MAC_COUNT=0; DIRECT_MAC_COUNT=0
[[ -z "$HOTSPOT_VPN_MACS" ]] || VPN_MAC_COUNT=$(( $(tr -cd ',' <<< "$HOTSPOT_VPN_MACS" | wc -c) + 1 ))
[[ -z "$HOTSPOT_DIRECT_MACS" ]] || DIRECT_MAC_COUNT=$(( $(tr -cd ',' <<< "$HOTSPOT_DIRECT_MACS" | wc -c) + 1 ))

state_get() {
  [[ -f "$STATE_FILE" ]] || return 0
  awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$STATE_FILE" 2>/dev/null || true
}

ipt_chain_reset() {
  local table="$1" chain="$2"
  iptables -w -t "$table" -N "$chain" 2>/dev/null || true
  iptables -w -t "$table" -F "$chain"
}

ipt_unhook() {
  local table="$1" base="$2" chain="$3"
  while iptables -w -t "$table" -D "$base" -j "$chain" 2>/dev/null; do :; done
}

cleanup_policy() {
  ipt_unhook mangle OUTPUT "$CHAIN_DNS"
  ipt_unhook mangle OUTPUT "$CHAIN_HOST"
  ipt_unhook mangle PREROUTING "$CHAIN_HOT"
  ipt_unhook nat PREROUTING "$CHAIN_HOT_DNS"
  ipt_unhook mangle OUTPUT "$CHAIN_MSS"
  ipt_unhook mangle FORWARD "$CHAIN_MSS"
  ipt_unhook filter OUTPUT "$CHAIN_KILL"
  ipt_unhook filter FORWARD "$CHAIN_KILL"
  for spec in "mangle:$CHAIN_DNS" "mangle:$CHAIN_HOST" "mangle:$CHAIN_HOT" "nat:$CHAIN_HOT_DNS" "mangle:$CHAIN_MSS" "filter:$CHAIN_KILL"; do
    table="${spec%%:*}"; chain="${spec#*:}"
    iptables -w -t "$table" -F "$chain" 2>/dev/null || true
    iptables -w -t "$table" -X "$chain" 2>/dev/null || true
  done
  while ip rule del pref "$RULE_DIRECT_PREF" fwmark "$MARK_DIRECT" table main >/dev/null 2>&1; do :; done
  while ip rule del pref "$RULE_VPN_PREF" fwmark "$MARK_VPN" table "$ROUTE_TABLE" >/dev/null 2>&1; do :; done
  ip route flush table "$ROUTE_TABLE" >/dev/null 2>&1 || true
  command -v ipset >/dev/null 2>&1 && ipset destroy "$IRAN_SET" >/dev/null 2>&1 || true
}

subnet_from_cidr() { python3 - "$1" <<'PY'
import ipaddress,sys
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
  local name dev cidr method line
  if [[ "$HOTSPOT_IFACE_REQUEST" != auto ]]; then
    if is_shared_iface "$HOTSPOT_IFACE_REQUEST"; then
      dev="$HOTSPOT_IFACE_REQUEST"
      cidr="$(ip -4 -o addr show dev "$dev" scope global | awk '{print $4}' | head -n1)"
      name="$(nmcli -g GENERAL.CONNECTION device show "$dev" 2>/dev/null | head -n1 || true)"
      HOTSPOT_CONNECTION="${name:-Hotspot}"; HOTSPOT_IFACE="$dev"; HOTSPOT_SUBNET="$(subnet_from_cidr "$cidr")"
    fi
    return 0
  fi
  if command -v nmcli >/dev/null 2>&1; then
    while IFS= read -r line; do
      dev="${line##*:}"; name="${line%:*}"
      [[ -n "$dev" && "$dev" != -- ]] || continue
      method="$(nmcli -g ipv4.method connection show "$name" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
      [[ "$method" == shared ]] || continue
      cidr="$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk '{print $4}' | head -n1)"
      [[ -n "$cidr" ]] || continue
      HOTSPOT_CONNECTION="$name"; HOTSPOT_IFACE="$dev"; HOTSPOT_SUBNET="$(subnet_from_cidr "$cidr")"; return 0
    done < <(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null || true)
  fi
}

recover_interface() {
  local iface="${1:-}"
  [[ "$RECOVER_NETWORK" == 1 && -n "$iface" ]] || return 0
  command -v nmcli >/dev/null 2>&1 || return 0
  nmcli device reapply "$iface" >/dev/null 2>&1 || true
  command -v resolvectl >/dev/null 2>&1 && resolvectl flush-caches >/dev/null 2>&1 || true
  if ! curl -4 --interface "$iface" --max-time 4 -sS http://1.1.1.1/ >/dev/null 2>&1; then
    nmcli device disconnect "$iface" >/dev/null 2>&1 || true
    sleep 1
    nmcli device connect "$iface" >/dev/null 2>&1 || true
  fi
}

build_host_chain() {
  ipt_chain_reset mangle "$CHAIN_HOST"
  iptables -w -t mangle -A "$CHAIN_HOST" -d "$SERVER_IP/32" -j RETURN
  for net in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 224.0.0.0/4 255.255.255.255/32; do
    iptables -w -t mangle -A "$CHAIN_HOST" -d "$net" -j MARK --set-mark "$MARK_DIRECT"
    iptables -w -t mangle -A "$CHAIN_HOST" -d "$net" -j RETURN
  done
  if [[ "$ROUTING_MODE" == iran_direct && "$IRAN_READY" == 1 ]]; then
    iptables -w -t mangle -A "$CHAIN_HOST" -m set --match-set "$IRAN_SET" dst -j MARK --set-mark "$MARK_DIRECT"
    iptables -w -t mangle -A "$CHAIN_HOST" -m set --match-set "$IRAN_SET" dst -j RETURN
  fi
  iptables -w -t mangle -A "$CHAIN_HOST" -m mark ! --mark "$MARK_DIRECT" -j MARK --set-mark "$MARK_VPN"
  ipt_unhook mangle OUTPUT "$CHAIN_HOST"
  iptables -w -t mangle -I OUTPUT 2 -j "$CHAIN_HOST"
}

load_iran_set() {
  IRAN_READY=0
  IRAN_ENTRIES=0
  [[ "$ROUTING_MODE" == iran_direct ]] || return 0
  command -v ipset >/dev/null 2>&1 || { echo "Iran Direct requires the 'ipset' package. Install it or choose VPN Everything." >&2; return 71; }
  install -d -m 0755 "$DATA_DIR"
  tmp="$(mktemp)"
  if curl -4 --max-time 15 -fsSL "$IRAN_SOURCE" -o "$tmp" 2>/dev/null && grep -Eq '^[0-9]+(\.[0-9]+){3}/[0-9]+$' "$tmp"; then install -m 0644 "$tmp" "$IRAN_CACHE"; fi
  rm -f "$tmp"
  [[ -s "$IRAN_CACHE" ]] || { echo "Iran Direct list is unavailable and no cached list exists." >&2; return 72; }
  {
    echo "create $IRAN_SET hash:net family inet hashsize 4096 maxelem 65536 -exist"
    echo "flush $IRAN_SET"
    awk '/^[0-9]+(\.[0-9]+){3}\/[0-9]+$/ {print "add '"$IRAN_SET"' "$1}' "$IRAN_CACHE"
  } | ipset restore -exist
  IRAN_ENTRIES="$(ipset list "$IRAN_SET" 2>/dev/null | awk '/Number of entries:/ {print $4; exit}')"
  [[ "${IRAN_ENTRIES:-0}" -gt 0 ]] || { echo "Iran Direct set loaded zero prefixes." >&2; return 72; }
  IRAN_READY=1
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

OLD_IFACE="$(state_get IFACE)"; OLD_VIP="$(state_get VIRTUAL_IP)"; OLD_HOT="$(state_get HOTSPOT_IFACE)"; OLD_SUBNET="$(state_get HOTSPOT_SUBNET)"
cleanup_policy
swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true
swanctl --terminate --ike surfshark-tr >/dev/null 2>&1 || true
ip link del "$XFRM_IF" >/dev/null 2>&1 || true
if [[ -n "$OLD_VIP" && -n "$OLD_IFACE" ]]; then ip addr del "$OLD_VIP/32" dev "$OLD_IFACE" >/dev/null 2>&1 || true; fi
if [[ -n "$OLD_IFACE" ]] && command -v resolvectl >/dev/null 2>&1; then resolvectl revert "$OLD_IFACE" >/dev/null 2>&1 || true; fi
if [[ -n "$OLD_HOT" && -n "$OLD_SUBNET" && -n "$OLD_VIP" ]]; then iptables -w -t nat -D POSTROUTING -s "$OLD_SUBNET" -o "$XFRM_IF" -j SNAT --to-source "$OLD_VIP" 2>/dev/null || true; fi
rm -f "$STATE_FILE"

IFS=',' read -r -a DNS_SERVERS <<< "$DNS_CSV"
VALID_DNS=()
for dns in "${DNS_SERVERS[@]}"; do dns="${dns//[[:space:]]/}"; [[ "$dns" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && VALID_DNS+=("$dns"); done
[[ ${#VALID_DNS[@]} -gt 0 ]] || VALID_DNS=(162.252.172.57 149.154.159.92)
DNS_CSV="$(IFS=,; echo "${VALID_DNS[*]}")"; HOTSPOT_DNS="${VALID_DNS[0]}"
detect_hotspot

ip link add "$XFRM_IF" type xfrm if_id "$XFRM_IF_ID"
ip link set "$XFRM_IF" mtu 1280 up

ESC_PASS="${SERVICE_PASS//\\/\\\\}"; ESC_PASS="${ESC_PASS//\"/\\\"}"
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
        if_id_in = $XFRM_IF_ID
        if_id_out = $XFRM_IF_ID
      }
    }
    vips = 0.0.0.0
    dpd_delay = 30s
  }
}
secrets { eap-milmit-surfshark { id = $SERVICE_USER; secret = "$ESC_PASS" } }
EOF
chmod 0600 "$CONF"
grep -Fq "eap_id = $SERVICE_USER" "$CONF" || exit 66
grep -Fq "id = $SERVER_IP" "$CONF" || exit 66
LOAD_CONNS="$(swanctl --load-conns 2>&1)"; printf '%s\n' "$LOAD_CONNS"
LOAD_CREDS="$(swanctl --load-creds 2>&1)"; printf '%s\n' "$LOAD_CREDS"
printf '%s\n' "$LOAD_CREDS" | grep -Fq "eap-milmit-surfshark" || { echo "MilMit EAP secret was not loaded." >&2; exit 66; }
swanctl --initiate --child "$CHILD_NAME"

SA_TEXT="$(swanctl --list-sas 2>&1 || true)"
VIRTUAL_IP="$(printf '%s\n' "$SA_TEXT" | sed -nE 's/.*local .*\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\].*/\1/p' | head -n1)"
[[ -n "$VIRTUAL_IP" ]] || { echo "$SA_TEXT"; echo "No virtual IPv4 was found." >&2; exit 67; }
IFACE="$(ip -4 route get "$SERVER_IP" | sed -nE 's/.* dev ([^ ]+).*/\1/p' | head -n1)"

ip route replace default dev "$XFRM_IF" src "$VIRTUAL_IP" table "$ROUTE_TABLE"
ip route replace blackhole default metric 32767 table "$ROUTE_TABLE" 2>/dev/null || true
ip rule add pref "$RULE_DIRECT_PREF" fwmark "$MARK_DIRECT" table main
ip rule add pref "$RULE_VPN_PREF" fwmark "$MARK_VPN" table "$ROUTE_TABLE"

IRAN_READY=0; IRAN_ENTRIES=0
build_host_chain
if [[ "$ROUTING_MODE" == iran_direct ]]; then
  if ! load_iran_set; then cleanup_policy; swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true; ip link del "$XFRM_IF" >/dev/null 2>&1 || true; recover_interface "$IFACE"; exit 72; fi
  build_host_chain
fi

ipt_chain_reset mangle "$CHAIN_DNS"
RESOLVED_UID="$(id -u systemd-resolve 2>/dev/null || id -u systemd-resolved 2>/dev/null || true)"
if [[ -n "$RESOLVED_UID" ]]; then iptables -w -t mangle -A "$CHAIN_DNS" -m owner --uid-owner "$RESOLVED_UID" -j MARK --set-mark "$MARK_VPN"; fi
ipt_unhook mangle OUTPUT "$CHAIN_DNS"; iptables -w -t mangle -I OUTPUT 1 -j "$CHAIN_DNS"

ipt_chain_reset mangle "$CHAIN_MSS"
iptables -w -t mangle -A "$CHAIN_MSS" -m mark --mark "$MARK_VPN" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS"
ipt_unhook mangle OUTPUT "$CHAIN_MSS"; iptables -w -t mangle -I OUTPUT 3 -j "$CHAIN_MSS"
ipt_unhook mangle FORWARD "$CHAIN_MSS"; iptables -w -t mangle -I FORWARD 1 -j "$CHAIN_MSS"

if command -v resolvectl >/dev/null 2>&1 && [[ -n "$IFACE" ]]; then
  resolvectl dns "$IFACE" "${VALID_DNS[@]}" || true
  resolvectl domain "$IFACE" '~.' || true
  resolvectl flush-caches || true
fi

HOTSPOT_POLICY_ACTIVE=0
if [[ -n "$HOTSPOT_IFACE" && -n "$HOTSPOT_SUBNET" && ( "$HOTSPOT_VPN" == 1 || -n "$HOTSPOT_VPN_MACS" || -n "$HOTSPOT_DIRECT_MACS" ) ]]; then
  HOTSPOT_POLICY_ACTIVE=1
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  ipt_chain_reset mangle "$CHAIN_HOT"
  for net in "$HOTSPOT_SUBNET" 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
    iptables -w -t mangle -A "$CHAIN_HOT" -d "$net" -j MARK --set-mark "$MARK_DIRECT"
    iptables -w -t mangle -A "$CHAIN_HOT" -d "$net" -j RETURN
  done
  if [[ -n "$HOTSPOT_DIRECT_MACS" ]]; then
    IFS=',' read -r -a direct_macs <<< "$HOTSPOT_DIRECT_MACS"
    for mac in "${direct_macs[@]}"; do
      iptables -w -t mangle -A "$CHAIN_HOT" -m mac --mac-source "$mac" -j MARK --set-mark "$MARK_DIRECT"
      iptables -w -t mangle -A "$CHAIN_HOT" -m mac --mac-source "$mac" -j RETURN
    done
  fi
  if [[ -n "$HOTSPOT_VPN_MACS" ]]; then
    IFS=',' read -r -a vpn_macs <<< "$HOTSPOT_VPN_MACS"
    for mac in "${vpn_macs[@]}"; do
      iptables -w -t mangle -A "$CHAIN_HOT" -m mac --mac-source "$mac" -j MARK --set-mark "$MARK_VPN"
      iptables -w -t mangle -A "$CHAIN_HOT" -m mac --mac-source "$mac" -j RETURN
    done
  fi
  if [[ "$HOTSPOT_VPN" == 1 ]]; then
    if [[ "$ROUTING_MODE" == iran_direct && "$IRAN_READY" == 1 ]]; then
      iptables -w -t mangle -A "$CHAIN_HOT" -m set --match-set "$IRAN_SET" dst -j MARK --set-mark "$MARK_DIRECT"
      iptables -w -t mangle -A "$CHAIN_HOT" -m set --match-set "$IRAN_SET" dst -j RETURN
    fi
    iptables -w -t mangle -A "$CHAIN_HOT" -j MARK --set-mark "$MARK_VPN"
  else
    iptables -w -t mangle -A "$CHAIN_HOT" -j MARK --set-mark "$MARK_DIRECT"
  fi
  ipt_unhook mangle PREROUTING "$CHAIN_HOT"
  iptables -w -t mangle -I PREROUTING 1 -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -j "$CHAIN_HOT"

  if [[ "$HOTSPOT_VPN" == 1 || -n "$HOTSPOT_VPN_MACS" ]]; then
    iptables -w -t nat -D POSTROUTING -s "$HOTSPOT_SUBNET" -o "$XFRM_IF" -j SNAT --to-source "$VIRTUAL_IP" 2>/dev/null || true
    iptables -w -t nat -I POSTROUTING 1 -s "$HOTSPOT_SUBNET" -o "$XFRM_IF" -j SNAT --to-source "$VIRTUAL_IP"
  fi

  ipt_chain_reset nat "$CHAIN_HOT_DNS"
  if [[ -n "$HOTSPOT_DIRECT_MACS" ]]; then
    IFS=',' read -r -a direct_dns_macs <<< "$HOTSPOT_DIRECT_MACS"
    for mac in "${direct_dns_macs[@]}"; do iptables -w -t nat -A "$CHAIN_HOT_DNS" -m mac --mac-source "$mac" -j RETURN; done
  fi
  if [[ -n "$HOTSPOT_VPN_MACS" ]]; then
    IFS=',' read -r -a vpn_dns_macs <<< "$HOTSPOT_VPN_MACS"
    for mac in "${vpn_dns_macs[@]}"; do
      iptables -w -t nat -A "$CHAIN_HOT_DNS" -m mac --mac-source "$mac" -p udp --dport 53 -j DNAT --to-destination "$HOTSPOT_DNS"
      iptables -w -t nat -A "$CHAIN_HOT_DNS" -m mac --mac-source "$mac" -p tcp --dport 53 -j DNAT --to-destination "$HOTSPOT_DNS"
      iptables -w -t nat -A "$CHAIN_HOT_DNS" -m mac --mac-source "$mac" -j RETURN
    done
  fi
  if [[ "$HOTSPOT_VPN" == 1 ]]; then
    iptables -w -t nat -A "$CHAIN_HOT_DNS" -p udp --dport 53 -j DNAT --to-destination "$HOTSPOT_DNS"
    iptables -w -t nat -A "$CHAIN_HOT_DNS" -p tcp --dport 53 -j DNAT --to-destination "$HOTSPOT_DNS"
  fi
  ipt_unhook nat PREROUTING "$CHAIN_HOT_DNS"
  iptables -w -t nat -I PREROUTING 1 -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -j "$CHAIN_HOT_DNS"
fi

ipt_chain_reset filter "$CHAIN_KILL"
if [[ "$KILL_SWITCH" == 1 ]]; then
  iptables -w -t filter -A "$CHAIN_KILL" -d "$SERVER_IP/32" -j RETURN
  for net in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16; do iptables -w -t filter -A "$CHAIN_KILL" -d "$net" -j RETURN; done
  iptables -w -t filter -A "$CHAIN_KILL" -m mark --mark "$MARK_VPN" -j RETURN
  if [[ "$ROUTING_MODE" == iran_direct || -n "$HOTSPOT_DIRECT_MACS" || "$HOTSPOT_VPN" == 0 ]]; then iptables -w -t filter -A "$CHAIN_KILL" -m mark --mark "$MARK_DIRECT" -j RETURN; fi
  iptables -w -t filter -A "$CHAIN_KILL" -j REJECT
  ipt_unhook filter OUTPUT "$CHAIN_KILL"; iptables -w -t filter -A OUTPUT -j "$CHAIN_KILL"
  if [[ "$HOTSPOT_POLICY_ACTIVE" == 1 ]]; then ipt_unhook filter FORWARD "$CHAIN_KILL"; iptables -w -t filter -A FORWARD -j "$CHAIN_KILL"; fi
fi

ip route flush cache >/dev/null 2>&1 || true
ROUTE_CHECK="$(ip -4 route get 1.1.1.1 mark "$MARK_VPN" 2>&1 || true)"
printf 'Marked route : %s\n' "$ROUTE_CHECK"
printf '%s' "$ROUTE_CHECK" | grep -Fq "dev $XFRM_IF" || { echo "Marked route does not select $XFRM_IF" >&2; cleanup_policy; exit 68; }

BEFORE_PKTS="$(iptables -w -t mangle -L "$CHAIN_HOST" -v -n -x 2>/dev/null | awk 'NR>2 {s+=$1} END{print s+0}')"
TRACE="$(curl -4 --max-time 12 -ks https://1.1.1.1/cdn-cgi/trace || true)"
AFTER_PKTS="$(iptables -w -t mangle -L "$CHAIN_HOST" -v -n -x 2>/dev/null | awk 'NR>2 {s+=$1} END{print s+0}')"
PUBLIC_IP="$(printf '%s\n' "$TRACE" | sed -n 's/^ip=//p' | head -n1)"; EXIT_COUNTRY="$(printf '%s\n' "$TRACE" | sed -n 's/^loc=//p' | head -n1)"
if [[ -z "$PUBLIC_IP" || "$AFTER_PKTS" -le "$BEFORE_PKTS" ]]; then
  echo "Marked system data-path verification failed." >&2
  cleanup_policy; swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true; ip link del "$XFRM_IF" >/dev/null 2>&1 || true; recover_interface "$IFACE"; exit 68
fi

NM_MARKER_ACTIVE=0
if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager.service 2>/dev/null; then
  nmcli connection delete "$NM_MARKER" >/dev/null 2>&1 || true
  if nmcli connection add type dummy ifname "$NM_MARKER_IF" con-name "$NM_MARKER" ipv4.method disabled ipv6.method disabled connection.autoconnect no >/dev/null 2>&1; then nmcli connection up "$NM_MARKER" >/dev/null 2>&1 && NM_MARKER_ACTIVE=1 || true; fi
fi

install -d -m 0755 "$STATE_DIR"
cat >"$STATE_FILE" <<EOF
VIRTUAL_IP=$VIRTUAL_IP
IFACE=$IFACE
MSS_VALUE=$MSS
DNS_CSV=$DNS_CSV
SERVER_IP=$SERVER_IP
PUBLIC_IP=$PUBLIC_IP
EXIT_COUNTRY=$EXIT_COUNTRY
MARK_VPN=$MARK_VPN
MARK_DIRECT=$MARK_DIRECT
RULE_VPN_PREF=$RULE_VPN_PREF
RULE_DIRECT_PREF=$RULE_DIRECT_PREF
SYSTEM_VPN=1
KILL_SWITCH=$KILL_SWITCH
ROUTING_MODE=$ROUTING_MODE
IRAN_SET_READY=$IRAN_READY
IRAN_SET_ENTRIES=${IRAN_ENTRIES:-0}
HOTSPOT_VPN=$HOTSPOT_VPN
HOTSPOT_IFACE_REQUEST=$HOTSPOT_IFACE_REQUEST
HOTSPOT_CONNECTION=$HOTSPOT_CONNECTION
HOTSPOT_IFACE=$HOTSPOT_IFACE
HOTSPOT_SUBNET=$HOTSPOT_SUBNET
HOTSPOT_DNS=$HOTSPOT_DNS
HOTSPOT_POLICY_ACTIVE=$HOTSPOT_POLICY_ACTIVE
HOTSPOT_VPN_MACS=$HOTSPOT_VPN_MACS
HOTSPOT_DIRECT_MACS=$HOTSPOT_DIRECT_MACS
HOTSPOT_VPN_MAC_COUNT=$VPN_MAC_COUNT
HOTSPOT_DIRECT_MAC_COUNT=$DIRECT_MAC_COUNT
RECOVER_NETWORK=$RECOVER_NETWORK
NM_MARKER_ACTIVE=$NM_MARKER_ACTIVE
EOF
chmod 0644 "$STATE_FILE"

printf '\nRestricted Surfshark IKEv2 is established\n'
printf 'Virtual IPv4 : %s\nMSS clamp    : %s\nDNS          : %s\nInterface    : %s\n' "$VIRTUAL_IP" "$MSS" "$DNS_CSV" "$IFACE"
printf 'Routing      : MARK %s -> table %s -> %s\n' "$MARK_VPN" "$ROUTE_TABLE" "$XFRM_IF"
printf 'Routing mode : %s\n' "$([[ "$ROUTING_MODE" == iran_direct ]] && echo 'Iran direct · foreign VPN' || echo 'VPN everything')"
printf 'Iran prefixes: %s\n' "${IRAN_ENTRIES:-0}"
printf 'Policy pkts  : %s -> %s\n' "$BEFORE_PKTS" "$AFTER_PKTS"
printf 'Kill switch  : %s\n' "$([[ "$KILL_SWITCH" == 1 ]] && echo ON || echo OFF)"
printf 'Hotspot VPN  : %s\n' "$([[ "$HOTSPOT_VPN" == 1 && -n "$HOTSPOT_IFACE" ]] && printf 'ON · %s · %s' "$HOTSPOT_IFACE" "$HOTSPOT_SUBNET" || echo OFF)"
printf 'Device policy: %s VPN MAC(s) · %s Direct MAC(s)\n' "$VPN_MAC_COUNT" "$DIRECT_MAC_COUNT"
printf '%s\n' "$SA_TEXT"
printf '\nSystem data-path test: OK\nData-path test: OK\nPublic IPv4 : %s\nExit country: %s\n' "$PUBLIC_IP" "${EXIT_COUNTRY:-unknown}"
