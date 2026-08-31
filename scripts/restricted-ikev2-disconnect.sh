#!/usr/bin/env bash
set -euo pipefail

CONN_NAME=milmit-surfshark-restricted
STATE_FILE=/run/milmit-surfshark/restricted.state
NM_MARKER_DEFAULT="Surfshark IKEv2 (Connected)"

if [[ $EUID -ne 0 ]]; then echo "This helper must run as root." >&2; exit 77; fi

state_get() {
  local key="$1"
  [[ -f "$STATE_FILE" ]] || return 0
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$STATE_FILE" 2>/dev/null || true
}

VIRTUAL_IP="$(state_get VIRTUAL_IP)"
IFACE="$(state_get IFACE)"
MSS_VALUE="$(state_get MSS_VALUE)"
NM_MARKER="$(state_get NM_MARKER)"
HOTSPOT_IFACE="$(state_get HOTSPOT_IFACE)"
HOTSPOT_SUBNET="$(state_get HOTSPOT_SUBNET)"
MSS_VALUE="${MSS_VALUE:-1200}"
NM_MARKER="${NM_MARKER:-$NM_MARKER_DEFAULT}"

swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true

if [[ -n "$VIRTUAL_IP" ]]; then
  iptables -t mangle -D OUTPUT -s "$VIRTUAL_IP/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_VALUE" 2>/dev/null || true
fi

if [[ -n "$HOTSPOT_IFACE" && -n "$HOTSPOT_SUBNET" && -n "$VIRTUAL_IP" ]]; then
  iptables -t nat -D POSTROUTING -s "$HOTSPOT_SUBNET" -j SNAT --to-source "$VIRTUAL_IP" 2>/dev/null || true
  iptables -t mangle -D FORWARD -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_VALUE" 2>/dev/null || true
  iptables -D FORWARD -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -o "$HOTSPOT_IFACE" -d "$HOTSPOT_SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
fi

if [[ -n "$IFACE" ]] && command -v resolvectl >/dev/null 2>&1; then
  resolvectl revert "$IFACE" 2>/dev/null || true
  resolvectl flush-caches 2>/dev/null || true
fi

if command -v nmcli >/dev/null 2>&1; then
  nmcli connection down "$NM_MARKER" >/dev/null 2>&1 || true
  nmcli connection delete "$NM_MARKER" >/dev/null 2>&1 || true
fi

rm -f "$STATE_FILE"
echo "Restricted Surfshark IKEv2 disconnected; hotspot VPN rules, Ubuntu marker and network overrides reverted."
