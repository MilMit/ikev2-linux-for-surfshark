#!/usr/bin/env bash
set -euo pipefail

CONN_NAME=milmit-surfshark-restricted
STATE_DIR=/run/milmit-surfshark
STATE_FILE=$STATE_DIR/restricted.state
DISCONNECTING=$STATE_DIR/disconnecting
MANUAL_DISCONNECTED=$STATE_DIR/manual-disconnected
NM_MARKER="Surfshark IKEv2 (Connected)"
XFRM_IF=milmitxfrm0
ROUTE_TABLE=220
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
CHAIN_DEVICE_BLOCK=MILMIT_DEVICE_BLOCK
DESKTOP=/usr/lib/milmit-surfshark/desktop-features.py

[[ $EUID -eq 0 ]] || { echo "This helper must run as root." >&2; exit 77; }
# A user can cancel while an endpoint attempt is still inside the connector.
# Stop only MilMit connector processes; this makes Disconnect/Cancel return
# promptly and prevents the old attempt from continuing with another endpoint.
pkill -TERM -f '/usr/lib/milmit-surfshark/restricted-ikev2-connect-v2.sh' >/dev/null 2>&1 || true
pkill -TERM -f '/usr/lib/milmit-surfshark/restricted-ikev2-connect.sh' >/dev/null 2>&1 || true
sleep 0.12
mkdir -p "$STATE_DIR"
# User/API disconnects are authoritative. Internal watchdog recovery sets
# MILMIT_DISCONNECT_REASON=watchdog so it does not accidentally create a
# persistent manual-disconnect marker and disable future recovery attempts.
if [[ "${MILMIT_DISCONNECT_REASON:-manual}" == manual ]]; then touch "$MANUAL_DISCONNECTED"; fi
touch "$DISCONNECTING"
trap 'rm -f "$DISCONNECTING"' EXIT

state_get(){ [[ -f "$STATE_FILE" ]] || return 0; awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$STATE_FILE" 2>/dev/null || true; }
ipt_unhook(){ local table="$1" base="$2" chain="$3"; while iptables -w -t "$table" -D "$base" -j "$chain" 2>/dev/null; do :; done; }
remove_chains(){
  ipt_unhook mangle OUTPUT "$CHAIN_DNS"; ipt_unhook mangle OUTPUT "$CHAIN_POLICY"; ipt_unhook mangle OUTPUT "$CHAIN_HOST"
  ipt_unhook mangle PREROUTING "$CHAIN_POLICY"; ipt_unhook mangle PREROUTING "$CHAIN_HOT"
  ipt_unhook nat PREROUTING "$CHAIN_HOT_DNS"; ipt_unhook mangle OUTPUT "$CHAIN_MSS"; ipt_unhook mangle FORWARD "$CHAIN_MSS"
  ipt_unhook filter OUTPUT "$CHAIN_BLOCK"; ipt_unhook filter FORWARD "$CHAIN_BLOCK"; ipt_unhook filter OUTPUT "$CHAIN_KILL"; ipt_unhook filter FORWARD "$CHAIN_KILL"; ipt_unhook filter FORWARD "$CHAIN_HOT_FWD"; ipt_unhook filter FORWARD "$CHAIN_DEVICE_BLOCK"
  for spec in "mangle:$CHAIN_DNS" "mangle:$CHAIN_POLICY" "mangle:$CHAIN_HOST" "mangle:$CHAIN_HOT" "nat:$CHAIN_HOT_DNS" "mangle:$CHAIN_MSS" "filter:$CHAIN_BLOCK" "filter:$CHAIN_KILL" "filter:$CHAIN_HOT_FWD" "filter:$CHAIN_DEVICE_BLOCK"; do table="${spec%%:*}"; chain="${spec#*:}"; iptables -w -t "$table" -F "$chain" 2>/dev/null || true; iptables -w -t "$table" -X "$chain" 2>/dev/null || true; done
}

VIRTUAL_IP="$(state_get VIRTUAL_IP)"; IFACE="$(state_get IFACE)"; HOTSPOT_SUBNET="$(state_get HOTSPOT_SUBNET)"; RECOVER_NETWORK="$(state_get RECOVER_NETWORK)"
swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true
swanctl --terminate --ike surfshark-tr >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do swanctl --list-sas 2>/dev/null | grep -qE 'milmit-surfshark-restricted|surfshark-tr' || break; sleep 0.2; swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true; swanctl --terminate --ike surfshark-tr >/dev/null 2>&1 || true; done
remove_chains
for pref in 100 101 102 103 104 105 106 107 108 109 110 220; do while ip rule del pref "$pref" >/dev/null 2>&1; do :; done; done
ip route flush table "$ROUTE_TABLE" >/dev/null 2>&1 || true; ip route flush cache >/dev/null 2>&1 || true
command -v ipset >/dev/null 2>&1 && { ipset destroy "$IRAN_SET" >/dev/null 2>&1 || true; ipset destroy MILMIT_FORCE_DIRECT >/dev/null 2>&1 || true; ipset destroy MILMIT_FORCE_VPN >/dev/null 2>&1 || true; ipset destroy MILMIT_BLOCK >/dev/null 2>&1 || true; }
if [[ -n "$HOTSPOT_SUBNET" && -n "$VIRTUAL_IP" ]]; then while iptables -w -t nat -D POSTROUTING -s "$HOTSPOT_SUBNET" -o "$XFRM_IF" -j SNAT --to-source "$VIRTUAL_IP" 2>/dev/null; do :; done; fi
if [[ -n "$HOTSPOT_SUBNET" ]] && command -v conntrack >/dev/null 2>&1; then conntrack -D -s "$HOTSPOT_SUBNET" >/dev/null 2>&1 || true; conntrack -D -d "$HOTSPOT_SUBNET" >/dev/null 2>&1 || true; fi
ip link del "$XFRM_IF" >/dev/null 2>&1 || true
if [[ -n "$IFACE" ]] && command -v resolvectl >/dev/null 2>&1; then resolvectl revert "$IFACE" >/dev/null 2>&1 || true; resolvectl flush-caches >/dev/null 2>&1 || true; fi
if command -v nmcli >/dev/null 2>&1; then nmcli connection down "$NM_MARKER" >/dev/null 2>&1 || true; nmcli connection delete "$NM_MARKER" >/dev/null 2>&1 || true; if [[ "${RECOVER_NETWORK:-1}" == 1 && -n "$IFACE" ]]; then nmcli device reapply "$IFACE" >/dev/null 2>&1 || true; fi; fi
rm -f "$STATE_FILE" "$STATE_DIR/live.state" "$STATE_DIR/watchdog-recovering"
# Lockdown is intentionally applied only after VPN teardown. If enabled it
# blocks normal Internet while still allowing local networking and the saved
# IKE endpoint so a reconnect can happen.
[[ -x "$DESKTOP" ]] && "$DESKTOP" lockdown-apply >/dev/null 2>&1 || true
left=0
swanctl --list-sas 2>/dev/null | grep -qE 'milmit-surfshark-restricted|surfshark-tr' && { echo "WARNING: IKE SA still present after disconnect." >&2; left=1; }
ip link show "$XFRM_IF" >/dev/null 2>&1 && { echo "WARNING: XFRM interface still present after disconnect." >&2; left=1; }
ip rule show 2>/dev/null | grep -qE 'lookup 220|table 220' && { echo "WARNING: VPN policy-routing rule still present after disconnect." >&2; left=1; }
[[ -e "$STATE_FILE" ]] && { echo "WARNING: VPN runtime state still present after disconnect." >&2; left=1; }
if ((left)); then echo "Disconnect teardown incomplete; not reporting a false success." >&2; exit 70; fi
echo "Restricted Surfshark IKEv2 fully disconnected. Direct Internet remains available unless Lockdown mode is enabled."
