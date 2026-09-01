#!/usr/bin/env bash
set -euo pipefail

CONN_NAME=milmit-surfshark-restricted
STATE_DIR=/run/milmit-surfshark
STATE_FILE=$STATE_DIR/restricted.state
DISCONNECTING=$STATE_DIR/disconnecting
NM_MARKER="Surfshark IKEv2 (Connected)"
XFRM_IF=milmitxfrm0
ROUTE_TABLE=220
MARK_VPN=0x112
MARK_DIRECT=0x113
IRAN_SET=MILMIT_IRAN
CHAIN_HOST=MILMIT_VPN_OUT
CHAIN_DNS=MILMIT_DNS_MARK
CHAIN_HOT=MILMIT_HOTSPOT_MARK
CHAIN_HOT_DNS=MILMIT_HOTSPOT_DNS
CHAIN_HOT_FWD=MILMIT_HOTSPOT_FWD
CHAIN_MSS=MILMIT_VPN_MSS
CHAIN_KILL=MILMIT_VPN_KILL
CHAIN_POLICY=MILMIT_ADV_POLICY
CHAIN_BLOCK=MILMIT_ADV_BLOCK

[[ $EUID -eq 0 ]] || { echo "This helper must run as root." >&2; exit 77; }
mkdir -p "$STATE_DIR"; touch "$DISCONNECTING"; trap 'rm -f "$DISCONNECTING"' EXIT
state_get(){ [[ -f "$STATE_FILE" ]] || return 0; awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$STATE_FILE" 2>/dev/null || true; }
ipt_unhook(){ local table="$1" base="$2" chain="$3"; while iptables -w -t "$table" -D "$base" -j "$chain" 2>/dev/null; do :; done; }
remove_chains(){
  ipt_unhook mangle OUTPUT "$CHAIN_DNS"; ipt_unhook mangle OUTPUT "$CHAIN_POLICY"; ipt_unhook mangle OUTPUT "$CHAIN_HOST"
  ipt_unhook mangle PREROUTING "$CHAIN_POLICY"; ipt_unhook mangle PREROUTING "$CHAIN_HOT"
  ipt_unhook nat PREROUTING "$CHAIN_HOT_DNS"; ipt_unhook mangle OUTPUT "$CHAIN_MSS"; ipt_unhook mangle FORWARD "$CHAIN_MSS"
  ipt_unhook filter OUTPUT "$CHAIN_BLOCK"; ipt_unhook filter FORWARD "$CHAIN_BLOCK"; ipt_unhook filter OUTPUT "$CHAIN_KILL"; ipt_unhook filter FORWARD "$CHAIN_KILL"; ipt_unhook filter FORWARD "$CHAIN_HOT_FWD"
  for spec in "mangle:$CHAIN_DNS" "mangle:$CHAIN_POLICY" "mangle:$CHAIN_HOST" "mangle:$CHAIN_HOT" "nat:$CHAIN_HOT_DNS" "mangle:$CHAIN_MSS" "filter:$CHAIN_BLOCK" "filter:$CHAIN_KILL" "filter:$CHAIN_HOT_FWD"; do
    table="${spec%%:*}"; chain="${spec#*:}"; iptables -w -t "$table" -F "$chain" 2>/dev/null || true; iptables -w -t "$table" -X "$chain" 2>/dev/null || true
  done
}

VIRTUAL_IP="$(state_get VIRTUAL_IP)"; IFACE="$(state_get IFACE)"; HOTSPOT_SUBNET="$(state_get HOTSPOT_SUBNET)"; RECOVER_NETWORK="$(state_get RECOVER_NETWORK)"
remove_chains
for pref in 100 101 102 103 104 105 106 107 108 109 110 220; do while ip rule del pref "$pref" >/dev/null 2>&1; do :; done; done
ip route flush table "$ROUTE_TABLE" >/dev/null 2>&1 || true; ip route flush cache >/dev/null 2>&1 || true
command -v ipset >/dev/null 2>&1 && { ipset destroy "$IRAN_SET" >/dev/null 2>&1 || true; ipset destroy MILMIT_FORCE_DIRECT >/dev/null 2>&1 || true; ipset destroy MILMIT_FORCE_VPN >/dev/null 2>&1 || true; ipset destroy MILMIT_BLOCK >/dev/null 2>&1 || true; }
if [[ -n "$HOTSPOT_SUBNET" && -n "$VIRTUAL_IP" ]]; then while iptables -w -t nat -D POSTROUTING -s "$HOTSPOT_SUBNET" -o "$XFRM_IF" -j SNAT --to-source "$VIRTUAL_IP" 2>/dev/null; do :; done; fi
if [[ -n "$HOTSPOT_SUBNET" ]] && command -v conntrack >/dev/null 2>&1; then conntrack -D -s "$HOTSPOT_SUBNET" >/dev/null 2>&1 || true; conntrack -D -d "$HOTSPOT_SUBNET" >/dev/null 2>&1 || true; fi
swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true; swanctl --terminate --ike surfshark-tr >/dev/null 2>&1 || true; ip link del "$XFRM_IF" >/dev/null 2>&1 || true
if [[ -n "$IFACE" ]] && command -v resolvectl >/dev/null 2>&1; then resolvectl revert "$IFACE" >/dev/null 2>&1 || true; resolvectl flush-caches >/dev/null 2>&1 || true; fi
if command -v nmcli >/dev/null 2>&1; then
  nmcli connection down "$NM_MARKER" >/dev/null 2>&1 || true; nmcli connection delete "$NM_MARKER" >/dev/null 2>&1 || true
  if [[ "${RECOVER_NETWORK:-1}" == 1 && -n "$IFACE" ]]; then nmcli device reapply "$IFACE" >/dev/null 2>&1 || true; fi
fi
rm -f "$STATE_FILE" "$STATE_DIR/live.state"
echo "Restricted Surfshark IKEv2 disconnected. Watchdog paused; hotspot forwarding/NAT/DNS, advanced policy, kill switch, XFRM and policy routing were restored."
