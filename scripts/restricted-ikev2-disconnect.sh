#!/usr/bin/env bash
set -euo pipefail

CONN_NAME=milmit-surfshark-restricted
STATE_FILE=/run/milmit-surfshark/restricted.state
NM_MARKER="Surfshark IKEv2 (Connected)"
XFRM_IF=milmitxfrm0
ROUTE_TABLE=220
MARK_VPN=0x112
MARK_DIRECT=0x113
RULE_DIRECT_PREF=109
RULE_VPN_PREF=110
IRAN_SET=MILMIT_IRAN
CHAIN_HOST=MILMIT_VPN_OUT
CHAIN_DNS=MILMIT_DNS_MARK
CHAIN_HOT=MILMIT_HOTSPOT_MARK
CHAIN_MSS=MILMIT_VPN_MSS
CHAIN_KILL=MILMIT_VPN_KILL

[[ $EUID -eq 0 ]] || { echo "This helper must run as root." >&2; exit 77; }

state_get() {
  [[ -f "$STATE_FILE" ]] || return 0
  awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$STATE_FILE" 2>/dev/null || true
}

ipt_unhook() {
  local table="$1" base="$2" chain="$3"
  while iptables -w -t "$table" -D "$base" -j "$chain" 2>/dev/null; do :; done
}

remove_chains() {
  ipt_unhook mangle OUTPUT "$CHAIN_DNS"
  ipt_unhook mangle OUTPUT "$CHAIN_HOST"
  ipt_unhook mangle PREROUTING "$CHAIN_HOT"
  ipt_unhook mangle OUTPUT "$CHAIN_MSS"
  ipt_unhook mangle FORWARD "$CHAIN_MSS"
  ipt_unhook filter OUTPUT "$CHAIN_KILL"
  for spec in "mangle:$CHAIN_DNS" "mangle:$CHAIN_HOST" "mangle:$CHAIN_HOT" "mangle:$CHAIN_MSS" "filter:$CHAIN_KILL"; do
    table="${spec%%:*}"; chain="${spec#*:}"
    iptables -w -t "$table" -F "$chain" 2>/dev/null || true
    iptables -w -t "$table" -X "$chain" 2>/dev/null || true
  done
}

VIRTUAL_IP="$(state_get VIRTUAL_IP)"
IFACE="$(state_get IFACE)"
HOTSPOT_IFACE="$(state_get HOTSPOT_IFACE)"
HOTSPOT_SUBNET="$(state_get HOTSPOT_SUBNET)"
HOTSPOT_DNS="$(state_get HOTSPOT_DNS)"
RECOVER_NETWORK="$(state_get RECOVER_NETWORK)"

remove_chains
while ip rule del pref "$RULE_DIRECT_PREF" fwmark "$MARK_DIRECT" table main >/dev/null 2>&1; do :; done
while ip rule del pref "$RULE_VPN_PREF" fwmark "$MARK_VPN" table "$ROUTE_TABLE" >/dev/null 2>&1; do :; done
ip route flush table "$ROUTE_TABLE" >/dev/null 2>&1 || true
ip route flush cache >/dev/null 2>&1 || true
command -v ipset >/dev/null 2>&1 && ipset destroy "$IRAN_SET" >/dev/null 2>&1 || true

if [[ -n "$HOTSPOT_SUBNET" && -n "$VIRTUAL_IP" ]]; then
  while iptables -w -t nat -D POSTROUTING -s "$HOTSPOT_SUBNET" -o "$XFRM_IF" -j SNAT --to-source "$VIRTUAL_IP" 2>/dev/null; do :; done
fi
if [[ -n "$HOTSPOT_IFACE" && -n "$HOTSPOT_SUBNET" && -n "$HOTSPOT_DNS" ]]; then
  while iptables -w -t nat -D PREROUTING -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -p udp --dport 53 -j DNAT --to-destination "$HOTSPOT_DNS" 2>/dev/null; do :; done
  while iptables -w -t nat -D PREROUTING -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -p tcp --dport 53 -j DNAT --to-destination "$HOTSPOT_DNS" 2>/dev/null; do :; done
fi
if [[ -n "$HOTSPOT_SUBNET" ]] && command -v conntrack >/dev/null 2>&1; then
  conntrack -D -s "$HOTSPOT_SUBNET" >/dev/null 2>&1 || true
  conntrack -D -d "$HOTSPOT_SUBNET" >/dev/null 2>&1 || true
fi

swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true
swanctl --terminate --ike surfshark-tr >/dev/null 2>&1 || true
ip link del "$XFRM_IF" >/dev/null 2>&1 || true

if [[ -n "$VIRTUAL_IP" && -n "$IFACE" ]]; then
  ip addr del "$VIRTUAL_IP/32" dev "$IFACE" >/dev/null 2>&1 || true
fi
if [[ -n "$IFACE" ]] && command -v resolvectl >/dev/null 2>&1; then
  resolvectl revert "$IFACE" >/dev/null 2>&1 || true
  resolvectl flush-caches >/dev/null 2>&1 || true
fi

if command -v nmcli >/dev/null 2>&1; then
  nmcli connection down "$NM_MARKER" >/dev/null 2>&1 || true
  nmcli connection delete "$NM_MARKER" >/dev/null 2>&1 || true
  if [[ "${RECOVER_NETWORK:-1}" == 1 && -n "$IFACE" ]]; then
    nmcli device reapply "$IFACE" >/dev/null 2>&1 || true
    sleep 1
    if ! curl -4 --interface "$IFACE" --max-time 4 -sS http://1.1.1.1/ >/dev/null 2>&1; then
      nmcli device disconnect "$IFACE" >/dev/null 2>&1 || true
      sleep 1
      nmcli device connect "$IFACE" >/dev/null 2>&1 || true
    fi
  fi
fi

rm -f "$STATE_FILE"
echo "Restricted Surfshark IKEv2 disconnected. fwmark/IPSet policy, kill switch, XFRM interface, hotspot NAT, DNS and physical-link state were restored."
