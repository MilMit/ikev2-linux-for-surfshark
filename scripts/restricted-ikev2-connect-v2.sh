#!/usr/bin/env bash
set -euo pipefail

SERVER_IP="${1:-}"
SERVICE_USER="${2:-}"
MSS="${3:-1200}"
DNS_CSV="${4:-162.252.172.57,149.154.159.92}"
HOTSPOT_VPN="${5:-1}"
RECOVER_NETWORK="${6:-1}"
HOTSPOT_IFACE_REQUEST="${7:-auto}"
KILL_SWITCH="${8:-1}"
ROUTING_MODE="${9:-vpn_all}"
HOTSPOT_VPN_MACS="${10:-}"
HOTSPOT_DIRECT_MACS="${11:-}"
SERVER_IDENTITY="${12:-ee-tll.prod.surfshark.com}"

CONF=/etc/swanctl/conf.d/milmit-surfshark-restricted.conf
CONN_NAME=milmit-surfshark-restricted
CHILD_NAME=milmit-restricted
STATE_DIR=/run/milmit-surfshark
STATE_FILE="$STATE_DIR/restricted.state"
CRED_DIR=/etc/milmit-surfshark
CRED_FILE="$CRED_DIR/credentials"
VAR_DIR=/var/lib/milmit-surfshark
IRAN_FILE="$VAR_DIR/iran-ipv4.txt"
IRAN_SET=MILMIT_IRAN
XFRM_IF=milmitxfrm0
XFRM_IF_ID=42
ROUTE_TABLE=220
MARK_VPN=0x112
MARK_DIRECT=0x113
RULE_ENDPOINT_PREF=100
RULE_LOCAL_PREF_BASE=101
RULE_DIRECT_PREF=109
RULE_VPN_PREF=110
CHAIN_HOST=MILMIT_VPN_OUT
CHAIN_MSS=MILMIT_VPN_MSS
CHAIN_KILL=MILMIT_VPN_KILL
HOTSPOT_POLICY=/usr/lib/milmit-surfshark/hotspot-device-policy.sh

[[ $EUID -eq 0 ]] || { echo "This helper must run as root." >&2; exit 77; }
[[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "invalid server IPv4" >&2; exit 64; }
[[ -n "$SERVICE_USER" && ${#SERVICE_USER} -le 128 ]] || { echo "invalid service username" >&2; exit 64; }
[[ "$SERVER_IDENTITY" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "invalid server identity" >&2; exit 64; }
[[ "$MSS" =~ ^[0-9]+$ && "$MSS" -ge 900 && "$MSS" -le 1400 ]] || { echo "MSS must be 900-1400" >&2; exit 64; }
[[ "$ROUTING_MODE" == vpn_all || "$ROUTING_MODE" == iran_direct ]] || { echo "invalid routing mode" >&2; exit 64; }

ipt_unhook() { local t="$1" b="$2" c="$3"; while iptables -w -t "$t" -D "$b" -j "$c" 2>/dev/null; do :; done; }
ipt_reset() { local t="$1" c="$2"; iptables -w -t "$t" -N "$c" 2>/dev/null || true; iptables -w -t "$t" -F "$c"; }
cleanup_rules() {
  while ip rule del pref "$RULE_ENDPOINT_PREF" >/dev/null 2>&1; do :; done
  for pref in 101 102 103 104 105 106 107 108; do while ip rule del pref "$pref" >/dev/null 2>&1; do :; done; done
  while ip rule del pref "$RULE_DIRECT_PREF" >/dev/null 2>&1; do :; done
  while ip rule del pref "$RULE_VPN_PREF" >/dev/null 2>&1; do :; done
  while ip rule del pref 220 >/dev/null 2>&1; do :; done
}
cleanup_policy() {
  ipt_unhook mangle OUTPUT "$CHAIN_HOST"; ipt_unhook mangle OUTPUT "$CHAIN_MSS"; ipt_unhook mangle FORWARD "$CHAIN_MSS"
  ipt_unhook filter OUTPUT "$CHAIN_KILL"; ipt_unhook filter FORWARD "$CHAIN_KILL"
  for spec in "mangle:$CHAIN_HOST" "mangle:$CHAIN_MSS" "filter:$CHAIN_KILL"; do
    local t="${spec%%:*}" c="${spec#*:}"
    iptables -w -t "$t" -F "$c" 2>/dev/null || true; iptables -w -t "$t" -X "$c" 2>/dev/null || true
  done
  cleanup_rules
  ip route flush table "$ROUTE_TABLE" >/dev/null 2>&1 || true
}

detect_hotspot_iface() {
  if [[ "$HOTSPOT_IFACE_REQUEST" != auto ]]; then
    ip link show "$HOTSPOT_IFACE_REQUEST" >/dev/null 2>&1 && printf '%s' "$HOTSPOT_IFACE_REQUEST"
    return
  fi
  command -v nmcli >/dev/null 2>&1 || return 0
  local d conn method state
  while IFS=: read -r d state; do
    [[ "$state" == connected && -n "$d" ]] || continue
    conn="$(nmcli -g GENERAL.CONNECTION device show "$d" 2>/dev/null | head -n1)"
    [[ -n "$conn" && "$conn" != -- ]] || continue
    method="$(nmcli -g ipv4.method connection show "$conn" 2>/dev/null | head -n1)"
    if [[ "$method" == shared ]]; then printf '%s' "$d"; return; fi
  done < <(nmcli -t -f DEVICE,STATE device status 2>/dev/null || true)
}

network_of_iface() {
  local dev="$1" cidr
  cidr="$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk '{print $4}' | head -n1)"
  [[ -n "$cidr" ]] || return 0
  python3 - "$cidr" <<'PY'
import ipaddress,sys
try: print(ipaddress.ip_interface(sys.argv[1]).network)
except Exception: pass
PY
}

SERVICE_PASS=""
if [[ ! -t 0 ]]; then IFS= read -r SERVICE_PASS || true; fi
install -d -m 0700 "$CRED_DIR"; install -d -m 0755 "$VAR_DIR"
if [[ -n "$SERVICE_PASS" ]]; then
  umask 077; printf 'SERVICE_USER=%q\nSERVICE_PASS=%q\n' "$SERVICE_USER" "$SERVICE_PASS" > "$CRED_FILE"
elif [[ -f "$CRED_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CRED_FILE"
else
  echo "Surfshark service password is required." >&2; exit 66
fi
[[ -n "${SERVICE_PASS:-}" ]] || { echo "Surfshark service password is empty." >&2; exit 66; }

cleanup_policy
swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true
ip link del "$XFRM_IF" >/dev/null 2>&1 || true
rm -f "$STATE_FILE"
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
    local {
      auth = eap-mschapv2
      id = $SERVICE_USER
      eap_id = $SERVICE_USER
    }
    remote {
      auth = pubkey
      id = $SERVER_IDENTITY
    }
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
secrets {
  eap-milmit-surfshark {
    id = $SERVICE_USER
    secret = "$ESC_PASS"
  }
}
EOF
chmod 0600 "$CONF"

LOAD_CONNS="$(swanctl --load-conns 2>&1)"; printf '%s\n' "$LOAD_CONNS"
LOAD_CREDS="$(swanctl --load-creds 2>&1)"; printf '%s\n' "$LOAD_CREDS"
CONF_DUMP="$(swanctl --list-conns 2>&1 || true)"; printf '%s\n' "$CONF_DUMP"
printf '%s\n' "$LOAD_CREDS" | grep -Fq "eap-milmit-surfshark" || { echo "MilMit EAP secret failed to load." >&2; exit 66; }
printf '%s\n' "$CONF_DUMP" | grep -Fq "id: $SERVICE_USER" || { echo "Parsed connection is missing service ID." >&2; exit 66; }
printf '%s\n' "$CONF_DUMP" | grep -Fq "eap_id: $SERVICE_USER" || { echo "Parsed connection is missing EAP ID." >&2; exit 66; }

swanctl --initiate --child "$CHILD_NAME"
SA_TEXT="$(swanctl --list-sas 2>&1 || true)"; printf '%s\n' "$SA_TEXT"
printf '%s\n' "$SA_TEXT" | grep -Fq "$CONN_NAME" || { echo "IKE SA was not established." >&2; exit 67; }
VIRTUAL_IP="$(printf '%s\n' "$SA_TEXT" | sed -nE 's/.*local .*\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\].*/\1/p' | head -n1)"
[[ -n "$VIRTUAL_IP" ]] || { echo "No virtual IPv4 was assigned." >&2; exit 67; }
PHYS_ROUTE="$(ip -4 route get "$SERVER_IP" 2>/dev/null || true)"
IFACE="$(sed -nE 's/.* dev ([^ ]+).*/\1/p' <<< "$PHYS_ROUTE" | head -n1)"
PHYS_SRC="$(sed -nE 's/.* src ([0-9.]+).*/\1/p' <<< "$PHYS_ROUTE" | head -n1)"
PHYS_GW="$(sed -nE 's/.* via ([0-9.]+).*/\1/p' <<< "$PHYS_ROUTE" | head -n1)"

ip route replace default dev "$XFRM_IF" src "$VIRTUAL_IP" table "$ROUTE_TABLE"
IRAN_READY=0
if [[ "$ROUTING_MODE" == iran_direct && -s "$IRAN_FILE" && -n "$IFACE" && -n "$PHYS_SRC" ]]; then
  ipset create "$IRAN_SET" hash:net family inet maxelem 200000 -exist
  ipset flush "$IRAN_SET"
  while IFS= read -r net; do
    [[ -n "$net" && "$net" != \#* ]] || continue
    ipset add "$IRAN_SET" "$net" -exist >/dev/null 2>&1 || continue
  done < "$IRAN_FILE"
  IRAN_READY=1
fi

cleanup_rules
ip rule add pref "$RULE_ENDPOINT_PREF" to "$SERVER_IP/32" table main
pref="$RULE_LOCAL_PREF_BASE"
for net in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 224.0.0.0/4 255.255.255.255/32; do ip rule add pref "$pref" to "$net" table main; pref=$((pref+1)); done
ip rule add pref "$RULE_DIRECT_PREF" fwmark "$MARK_DIRECT" table main
ip rule add pref "$RULE_VPN_PREF" table "$ROUTE_TABLE"

ipt_reset mangle "$CHAIN_HOST"
# Respect marks set by the higher-priority policy engine. On iptables-nft the
# negation belongs to the --mark option, not before -m.
iptables -w -t mangle -A "$CHAIN_HOST" -m mark ! --mark 0 -j RETURN
iptables -w -t mangle -A "$CHAIN_HOST" -d "$SERVER_IP/32" -j RETURN
for net in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 224.0.0.0/4 255.255.255.255/32; do
  iptables -w -t mangle -A "$CHAIN_HOST" -d "$net" -j MARK --set-mark "$MARK_DIRECT"; iptables -w -t mangle -A "$CHAIN_HOST" -d "$net" -j RETURN
done
if [[ "$IRAN_READY" == 1 ]]; then
  iptables -w -t mangle -A "$CHAIN_HOST" -m set --match-set "$IRAN_SET" dst -j MARK --set-mark "$MARK_DIRECT"
  iptables -w -t mangle -A "$CHAIN_HOST" -m set --match-set "$IRAN_SET" dst -j RETURN
fi
iptables -w -t mangle -A "$CHAIN_HOST" -j MARK --set-mark "$MARK_VPN"

ipt_reset mangle "$CHAIN_MSS"
iptables -w -t mangle -A "$CHAIN_MSS" -p tcp --tcp-flags SYN,RST SYN -o "$XFRM_IF" -j TCPMSS --set-mss "$MSS"
iptables -w -t mangle -A "$CHAIN_MSS" -p tcp --tcp-flags SYN,RST SYN -i "$XFRM_IF" -j TCPMSS --set-mss "$MSS"
ipt_unhook mangle OUTPUT "$CHAIN_MSS"; iptables -w -t mangle -I OUTPUT 1 -j "$CHAIN_MSS"
ipt_unhook mangle OUTPUT "$CHAIN_HOST"; iptables -w -t mangle -I OUTPUT 1 -j "$CHAIN_HOST"
ipt_unhook mangle FORWARD "$CHAIN_MSS"; iptables -w -t mangle -I FORWARD 1 -j "$CHAIN_MSS"

IFS=',' read -r -a DNS_ARR <<< "$DNS_CSV"
if command -v resolvectl >/dev/null 2>&1 && [[ -n "$IFACE" ]]; then resolvectl dns "$IFACE" "${DNS_ARR[@]}" || true; resolvectl domain "$IFACE" '~.' || true; resolvectl flush-caches || true; fi

ROUTE_CHECK="$(ip -4 route get 1.1.1.1 2>&1 || true)"; printf 'System route : %s\n' "$ROUTE_CHECK"
printf '%s' "$ROUTE_CHECK" | grep -Fq "dev $XFRM_IF" || { echo "System route does not select $XFRM_IF" >&2; cleanup_policy; exit 68; }
printf '%s' "$ROUTE_CHECK" | grep -Fq "src $VIRTUAL_IP" || { echo "System route did not select Surfshark virtual source." >&2; cleanup_policy; exit 68; }
BEFORE_TX="$(cat /sys/class/net/$XFRM_IF/statistics/tx_packets 2>/dev/null || echo 0)"
TRACE="$(curl -4 --connect-timeout 6 --max-time 15 -ks https://1.1.1.1/cdn-cgi/trace || true)"
AFTER_TX="$(cat /sys/class/net/$XFRM_IF/statistics/tx_packets 2>/dev/null || echo 0)"
PUBLIC_IP="$(sed -n 's/^ip=//p' <<< "$TRACE" | head -n1)"; EXIT_COUNTRY="$(sed -n 's/^loc=//p' <<< "$TRACE" | head -n1)"
printf 'XFRM packets  : %s -> %s\n' "$BEFORE_TX" "$AFTER_TX"
[[ -n "$PUBLIC_IP" && "$AFTER_TX" -gt "$BEFORE_TX" ]] || { echo "System data-path verification failed." >&2; cleanup_policy; exit 68; }

HOTSPOT_IFACE="$(detect_hotspot_iface)"
HOTSPOT_SUBNET=""
HOTSPOT_DNS="${DNS_ARR[0]:-162.252.172.57}"
if [[ -n "$HOTSPOT_IFACE" ]]; then HOTSPOT_SUBNET="$(network_of_iface "$HOTSPOT_IFACE")"; fi

install -d -m 0755 "$STATE_DIR"
cat >"$STATE_FILE" <<EOF
VIRTUAL_IP=$VIRTUAL_IP
IFACE=$IFACE
MSS_VALUE=$MSS
DNS_CSV=$DNS_CSV
SERVER_IP=$SERVER_IP
SERVER_IDENTITY=$SERVER_IDENTITY
PUBLIC_IP=$PUBLIC_IP
EXIT_COUNTRY=$EXIT_COUNTRY
MARK_VPN=$MARK_VPN
MARK_DIRECT=$MARK_DIRECT
SYSTEM_VPN=1
KILL_SWITCH=$KILL_SWITCH
ROUTING_MODE=$ROUTING_MODE
IRAN_SET_READY=$IRAN_READY
HOTSPOT_VPN=$HOTSPOT_VPN
HOTSPOT_IFACE_REQUEST=$HOTSPOT_IFACE_REQUEST
HOTSPOT_IFACE=$HOTSPOT_IFACE
HOTSPOT_SUBNET=$HOTSPOT_SUBNET
HOTSPOT_DNS=$HOTSPOT_DNS
HOTSPOT_VPN_MACS=$HOTSPOT_VPN_MACS
HOTSPOT_DIRECT_MACS=$HOTSPOT_DIRECT_MACS
RECOVER_NETWORK=$RECOVER_NETWORK
EOF
chmod 0644 "$STATE_FILE"

if [[ -n "$HOTSPOT_IFACE" && -n "$HOTSPOT_SUBNET" && -x "$HOTSPOT_POLICY" ]]; then
  sysctl -qw net.ipv4.ip_forward=1 || true
  "$HOTSPOT_POLICY" "$HOTSPOT_VPN" "$HOTSPOT_VPN_MACS" "$HOTSPOT_DIRECT_MACS" || {
    echo "Hotspot policy could not be applied; system VPN remains connected." >&2
  }
fi

printf '\nRestricted Surfshark IKEv2 is established\n'
printf 'Server ID     : %s\n' "$SERVER_IDENTITY"
printf 'Virtual IPv4  : %s\n' "$VIRTUAL_IP"
printf 'Routing mode  : %s\n' "$ROUTING_MODE"
printf 'Data-path test: OK\n'
printf 'Public IPv4   : %s\n' "$PUBLIC_IP"
printf 'Exit country  : %s\n' "${EXIT_COUNTRY:-unknown}"
if [[ -n "$HOTSPOT_IFACE" ]]; then printf 'Hotspot iface  : %s\n' "$HOTSPOT_IFACE"; fi
