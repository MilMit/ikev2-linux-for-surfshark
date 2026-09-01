#!/usr/bin/env bash
set -euo pipefail

DEFAULT_VPN="${1:-1}"
VPN_MACS="${2:-}"
DIRECT_MACS="${3:-}"
STATE_FILE=/run/milmit-surfshark/restricted.state
CHAIN_HOT=MILMIT_HOTSPOT_MARK
CHAIN_HOT_DNS=MILMIT_HOTSPOT_DNS
CHAIN_HOT_FWD=MILMIT_HOTSPOT_FWD
MARK_VPN=0x112
MARK_DIRECT=0x113
IRAN_SET=MILMIT_IRAN
XFRM_IF=milmitxfrm0

[[ $EUID -eq 0 ]] || { echo "This helper must run as root." >&2; exit 77; }
[[ "$DEFAULT_VPN" == 0 || "$DEFAULT_VPN" == 1 ]] || { echo "invalid default hotspot policy" >&2; exit 64; }
[[ -z "$VPN_MACS" || "$VPN_MACS" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}(,([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})*$ ]] || { echo "invalid VPN MAC list" >&2; exit 64; }
[[ -z "$DIRECT_MACS" || "$DIRECT_MACS" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}(,([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})*$ ]] || { echo "invalid Direct MAC list" >&2; exit 64; }
[[ -f "$STATE_FILE" ]] || { echo "VPN is not connected; policy was saved for next connection only."; exit 3; }

state_get(){ awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$STATE_FILE" 2>/dev/null || true; }
normalize_csv(){ local csv="$1" out="" mac; IFS=',' read -r -a arr <<< "$csv"; for mac in "${arr[@]:-}"; do [[ -n "$mac" ]] || continue; mac="${mac^^}"; if [[ -z "$out" ]]; then out="$mac"; elif [[ ",$out," != *",$mac,"* ]]; then out="$out,$mac"; fi; done; printf '%s' "$out"; }
count_csv(){ local v="$1"; [[ -z "$v" ]] && { echo 0; return; }; echo $(( $(tr -cd ',' <<< "$v" | wc -c) + 1 )); }

VPN_MACS="$(normalize_csv "$VPN_MACS")"; DIRECT_MACS="$(normalize_csv "$DIRECT_MACS")"
if [[ -n "$VPN_MACS" && -n "$DIRECT_MACS" ]]; then IFS=',' read -r -a check <<< "$VPN_MACS"; for mac in "${check[@]}"; do [[ ",$DIRECT_MACS," != *",$mac,"* ]] || { echo "MAC $mac cannot be both VPN and Direct." >&2; exit 64; }; done; fi

HOTSPOT_IFACE="$(state_get HOTSPOT_IFACE)"; HOTSPOT_SUBNET="$(state_get HOTSPOT_SUBNET)"; HOTSPOT_DNS="$(state_get HOTSPOT_DNS)"; VIRTUAL_IP="$(state_get VIRTUAL_IP)"; ROUTING_MODE="$(state_get ROUTING_MODE)"; IRAN_READY="$(state_get IRAN_SET_READY)"
[[ -n "$HOTSPOT_IFACE" && -n "$HOTSPOT_SUBNET" ]] || { echo "No active hotspot was detected in current VPN state." >&2; exit 4; }
[[ -n "$HOTSPOT_DNS" ]] || HOTSPOT_DNS=162.252.172.57
sysctl -q -w net.ipv4.ip_forward=1 || true

iptables -w -t mangle -N "$CHAIN_HOT" 2>/dev/null || true; iptables -w -t mangle -F "$CHAIN_HOT"
# Preserve higher-priority advanced policy marks.
iptables -w -t mangle -A "$CHAIN_HOT" ! -m mark --mark 0 -j RETURN
for net in "$HOTSPOT_SUBNET" 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do iptables -w -t mangle -A "$CHAIN_HOT" -d "$net" -j MARK --set-mark "$MARK_DIRECT"; iptables -w -t mangle -A "$CHAIN_HOT" -d "$net" -j RETURN; done
if [[ -n "$DIRECT_MACS" ]]; then IFS=',' read -r -a arr <<< "$DIRECT_MACS"; for mac in "${arr[@]}"; do iptables -w -t mangle -A "$CHAIN_HOT" -m mac --mac-source "$mac" -j MARK --set-mark "$MARK_DIRECT"; iptables -w -t mangle -A "$CHAIN_HOT" -m mac --mac-source "$mac" -j RETURN; done; fi
if [[ -n "$VPN_MACS" ]]; then IFS=',' read -r -a arr <<< "$VPN_MACS"; for mac in "${arr[@]}"; do iptables -w -t mangle -A "$CHAIN_HOT" -m mac --mac-source "$mac" -j MARK --set-mark "$MARK_VPN"; iptables -w -t mangle -A "$CHAIN_HOT" -m mac --mac-source "$mac" -j RETURN; done; fi
if [[ "$DEFAULT_VPN" == 1 ]]; then
  if [[ "$ROUTING_MODE" == iran_direct && "$IRAN_READY" == 1 ]] && ipset list "$IRAN_SET" >/dev/null 2>&1; then iptables -w -t mangle -A "$CHAIN_HOT" -m set --match-set "$IRAN_SET" dst -j MARK --set-mark "$MARK_DIRECT"; iptables -w -t mangle -A "$CHAIN_HOT" -m set --match-set "$IRAN_SET" dst -j RETURN; fi
  iptables -w -t mangle -A "$CHAIN_HOT" -j MARK --set-mark "$MARK_VPN"
else iptables -w -t mangle -A "$CHAIN_HOT" -j MARK --set-mark "$MARK_DIRECT"; fi
while iptables -w -t mangle -D PREROUTING -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -j "$CHAIN_HOT" 2>/dev/null; do :; done
iptables -w -t mangle -I PREROUTING 1 -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -j "$CHAIN_HOT"

iptables -w -t nat -N "$CHAIN_HOT_DNS" 2>/dev/null || true; iptables -w -t nat -F "$CHAIN_HOT_DNS"
if [[ -n "$DIRECT_MACS" ]]; then IFS=',' read -r -a arr <<< "$DIRECT_MACS"; for mac in "${arr[@]}"; do iptables -w -t nat -A "$CHAIN_HOT_DNS" -m mac --mac-source "$mac" -j RETURN; done; fi
if [[ -n "$VPN_MACS" ]]; then IFS=',' read -r -a arr <<< "$VPN_MACS"; for mac in "${arr[@]}"; do iptables -w -t nat -A "$CHAIN_HOT_DNS" -m mac --mac-source "$mac" -p udp --dport 53 -j DNAT --to-destination "$HOTSPOT_DNS"; iptables -w -t nat -A "$CHAIN_HOT_DNS" -m mac --mac-source "$mac" -p tcp --dport 53 -j DNAT --to-destination "$HOTSPOT_DNS"; iptables -w -t nat -A "$CHAIN_HOT_DNS" -m mac --mac-source "$mac" -j RETURN; done; fi
if [[ "$DEFAULT_VPN" == 1 ]]; then iptables -w -t nat -A "$CHAIN_HOT_DNS" -p udp --dport 53 -j DNAT --to-destination "$HOTSPOT_DNS"; iptables -w -t nat -A "$CHAIN_HOT_DNS" -p tcp --dport 53 -j DNAT --to-destination "$HOTSPOT_DNS"; fi
while iptables -w -t nat -D PREROUTING -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -j "$CHAIN_HOT_DNS" 2>/dev/null; do :; done
iptables -w -t nat -I PREROUTING 1 -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -j "$CHAIN_HOT_DNS"

if [[ -n "$VIRTUAL_IP" ]]; then
  while iptables -w -t nat -D POSTROUTING -s "$HOTSPOT_SUBNET" -o "$XFRM_IF" -j SNAT --to-source "$VIRTUAL_IP" 2>/dev/null; do :; done
  if [[ "$DEFAULT_VPN" == 1 || -n "$VPN_MACS" ]]; then iptables -w -t nat -I POSTROUTING 1 -s "$HOTSPOT_SUBNET" -o "$XFRM_IF" -j SNAT --to-source "$VIRTUAL_IP"; fi
fi

# Explicit forwarding is required on hosts with Docker/libvirt/UFW policies. This
# is what removes the Android "connected, no Internet" exclamation in the common case.
iptables -w -t filter -N "$CHAIN_HOT_FWD" 2>/dev/null || true; iptables -w -t filter -F "$CHAIN_HOT_FWD"
iptables -w -t filter -A "$CHAIN_HOT_FWD" -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -o "$XFRM_IF" -j ACCEPT
iptables -w -t filter -A "$CHAIN_HOT_FWD" -i "$XFRM_IF" -o "$HOTSPOT_IFACE" -d "$HOTSPOT_SUBNET" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# Direct-policy traffic is allowed out the physical uplink by the main route.
iptables -w -t filter -A "$CHAIN_HOT_FWD" -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -m mark --mark "$MARK_DIRECT" -j ACCEPT
iptables -w -t filter -A "$CHAIN_HOT_FWD" -o "$HOTSPOT_IFACE" -d "$HOTSPOT_SUBNET" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
while iptables -w -t filter -D FORWARD -j "$CHAIN_HOT_FWD" 2>/dev/null; do :; done
iptables -w -t filter -I FORWARD 1 -j "$CHAIN_HOT_FWD"

VPN_COUNT="$(count_csv "$VPN_MACS")"; DIRECT_COUNT="$(count_csv "$DIRECT_MACS")"
tmp="$(mktemp)"; awk -F= '!($1=="HOTSPOT_VPN" || $1=="HOTSPOT_VPN_MACS" || $1=="HOTSPOT_DIRECT_MACS" || $1=="HOTSPOT_VPN_MAC_COUNT" || $1=="HOTSPOT_DIRECT_MAC_COUNT") {print}' "$STATE_FILE" > "$tmp"
cat >> "$tmp" <<EOF
HOTSPOT_VPN=$DEFAULT_VPN
HOTSPOT_VPN_MACS=$VPN_MACS
HOTSPOT_DIRECT_MACS=$DIRECT_MACS
HOTSPOT_VPN_MAC_COUNT=$VPN_COUNT
HOTSPOT_DIRECT_MAC_COUNT=$DIRECT_COUNT
EOF
install -m 0644 "$tmp" "$STATE_FILE"; rm -f "$tmp"
command -v conntrack >/dev/null 2>&1 && { conntrack -D -s "$HOTSPOT_SUBNET" >/dev/null 2>&1 || true; conntrack -D -d "$HOTSPOT_SUBNET" >/dev/null 2>&1 || true; }
ip route flush cache >/dev/null 2>&1 || true
printf 'Hotspot device policy applied live: iface=%s subnet=%s default=%s VPN=%s Direct=%s DNS=%s\n' "$HOTSPOT_IFACE" "$HOTSPOT_SUBNET" "$([[ "$DEFAULT_VPN" == 1 ]] && echo VPN || echo Direct)" "$VPN_COUNT" "$DIRECT_COUNT" "$HOTSPOT_DNS"
