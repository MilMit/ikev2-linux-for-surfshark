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
XFRM_IF=milmitxfrm0
XFRM_IF_ID=42
ROUTE_TABLE=220
MARK_VPN=0x112
MARK_DIRECT=0x113
RULE_DIRECT_PREF=109
RULE_VPN_PREF=110
CHAIN_HOST=MILMIT_VPN_OUT
CHAIN_MSS=MILMIT_VPN_MSS

[[ $EUID -eq 0 ]] || { echo "This helper must run as root." >&2; exit 77; }
[[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "invalid server IPv4" >&2; exit 64; }
[[ -n "$SERVICE_USER" && ${#SERVICE_USER} -le 128 ]] || { echo "invalid service username" >&2; exit 64; }
[[ "$SERVER_IDENTITY" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "invalid server identity" >&2; exit 64; }
[[ "$MSS" =~ ^[0-9]+$ && "$MSS" -ge 900 && "$MSS" -le 1400 ]] || { echo "MSS must be 900-1400" >&2; exit 64; }

ipt_unhook() { local t="$1" b="$2" c="$3"; while iptables -w -t "$t" -D "$b" -j "$c" 2>/dev/null; do :; done; }
ipt_reset() { local t="$1" c="$2"; iptables -w -t "$t" -N "$c" 2>/dev/null || true; iptables -w -t "$t" -F "$c"; }
ipt_hook_front() { local t="$1" b="$2" c="$3"; ipt_unhook "$t" "$b" "$c"; iptables -w -t "$t" -I "$b" 1 -j "$c"; }
cleanup_policy() {
  ipt_unhook mangle OUTPUT "$CHAIN_HOST"; ipt_unhook mangle OUTPUT "$CHAIN_MSS"; ipt_unhook mangle FORWARD "$CHAIN_MSS"
  for c in "$CHAIN_HOST" "$CHAIN_MSS"; do iptables -w -t mangle -F "$c" 2>/dev/null || true; iptables -w -t mangle -X "$c" 2>/dev/null || true; done
  while ip rule del pref "$RULE_DIRECT_PREF" fwmark "$MARK_DIRECT" table main >/dev/null 2>&1; do :; done
  while ip rule del pref "$RULE_VPN_PREF" fwmark "$MARK_VPN" table "$ROUTE_TABLE" >/dev/null 2>&1; do :; done
  ip route flush table "$ROUTE_TABLE" >/dev/null 2>&1 || true
}

SERVICE_PASS=""
if [[ ! -t 0 ]]; then IFS= read -r SERVICE_PASS || true; fi
install -d -m 0700 "$CRED_DIR"
if [[ -n "$SERVICE_PASS" ]]; then umask 077; printf 'SERVICE_USER=%q\nSERVICE_PASS=%q\n' "$SERVICE_USER" "$SERVICE_PASS" > "$CRED_FILE"; elif [[ -f "$CRED_FILE" ]]; then source "$CRED_FILE"; else echo "Surfshark service password is required." >&2; exit 66; fi
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
    local { auth = eap-mschapv2; id = $SERVICE_USER; eap_id = $SERVICE_USER }
    remote { auth = pubkey; id = $SERVER_IDENTITY }
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

swanctl --load-conns
swanctl --load-creds
swanctl --initiate --child "$CHILD_NAME"
SA_TEXT="$(swanctl --list-sas 2>&1 || true)"; printf '%s\n' "$SA_TEXT"
printf '%s\n' "$SA_TEXT" | grep -Fq "$CONN_NAME" || { echo "IKE SA was not established." >&2; exit 67; }
VIRTUAL_IP="$(printf '%s\n' "$SA_TEXT" | sed -nE 's/.*local .*\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\].*/\1/p' | head -n1)"
[[ -n "$VIRTUAL_IP" ]] || { echo "No virtual IPv4 was assigned." >&2; exit 67; }
IFACE="$(ip -4 route get "$SERVER_IP" | sed -nE 's/.* dev ([^ ]+).*/\1/p' | head -n1)"

ip route replace default dev "$XFRM_IF" src "$VIRTUAL_IP" table "$ROUTE_TABLE"
ip rule add pref "$RULE_DIRECT_PREF" fwmark "$MARK_DIRECT" table main
ip rule add pref "$RULE_VPN_PREF" fwmark "$MARK_VPN" table "$ROUTE_TABLE"

ipt_reset mangle "$CHAIN_HOST"
iptables -w -t mangle -A "$CHAIN_HOST" -d "$SERVER_IP/32" -j RETURN
for net in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 224.0.0.0/4 255.255.255.255/32; do iptables -w -t mangle -A "$CHAIN_HOST" -d "$net" -j MARK --set-mark "$MARK_DIRECT"; iptables -w -t mangle -A "$CHAIN_HOST" -d "$net" -j RETURN; done
iptables -w -t mangle -A "$CHAIN_HOST" -j MARK --set-mark "$MARK_VPN"
ipt_hook_front mangle OUTPUT "$CHAIN_HOST"

ipt_reset mangle "$CHAIN_MSS"
iptables -w -t mangle -A "$CHAIN_MSS" -m mark --mark "$MARK_VPN" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS"
ipt_hook_front mangle OUTPUT "$CHAIN_MSS"
ipt_hook_front mangle FORWARD "$CHAIN_MSS"

IFS=',' read -r -a DNS_ARR <<< "$DNS_CSV"
if command -v resolvectl >/dev/null 2>&1 && [[ -n "$IFACE" ]]; then resolvectl dns "$IFACE" "${DNS_ARR[@]}" || true; resolvectl domain "$IFACE" '~.' || true; resolvectl flush-caches || true; fi

ROUTE_CHECK="$(ip -4 route get 1.1.1.1 mark "$MARK_VPN" 2>&1 || true)"; printf 'Marked route : %s\n' "$ROUTE_CHECK"
printf '%s' "$ROUTE_CHECK" | grep -Fq "dev $XFRM_IF" || { echo "Marked route does not select $XFRM_IF" >&2; cleanup_policy; exit 68; }
TRACE="$(curl -4 --max-time 12 -ks https://1.1.1.1/cdn-cgi/trace || true)"
PUBLIC_IP="$(printf '%s\n' "$TRACE" | sed -n 's/^ip=//p' | head -n1)"; EXIT_COUNTRY="$(printf '%s\n' "$TRACE" | sed -n 's/^loc=//p' | head -n1)"
[[ -n "$PUBLIC_IP" ]] || { echo "System data-path verification failed." >&2; cleanup_policy; exit 68; }

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
HOTSPOT_VPN=$HOTSPOT_VPN
HOTSPOT_IFACE_REQUEST=$HOTSPOT_IFACE_REQUEST
HOTSPOT_VPN_MACS=$HOTSPOT_VPN_MACS
HOTSPOT_DIRECT_MACS=$HOTSPOT_DIRECT_MACS
RECOVER_NETWORK=$RECOVER_NETWORK
EOF
chmod 0644 "$STATE_FILE"
printf '\nRestricted Surfshark IKEv2 is established\nServer ID: %s\nVirtual IPv4: %s\nData-path test: OK\nPublic IPv4: %s\nExit country: %s\n' "$SERVER_IDENTITY" "$VIRTUAL_IP" "$PUBLIC_IP" "${EXIT_COUNTRY:-unknown}"
