#!/usr/bin/env bash
set -euo pipefail

CONN_NAME=milmit-surfshark-restricted
STATE_FILE=/run/milmit-surfshark/restricted.state
VIRTUAL_IP=""
IFACE=""
MSS_VALUE=1200
NM_MARKER="Surfshark IKEv2 (Connected)"
HOTSPOT_IFACE=""
HOTSPOT_SUBNET=""

if [[ $EUID -ne 0 ]]; then echo "This helper must run as root." >&2; exit 77; fi

if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE" || true
fi

swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true

if [[ -n "${VIRTUAL_IP:-}" ]]; then
  iptables -t mangle -D OUTPUT -s "$VIRTUAL_IP/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "${MSS_VALUE:-1200}" 2>/dev/null || true
fi

if [[ -n "${HOTSPOT_IFACE:-}" && -n "${HOTSPOT_SUBNET:-}" && -n "${VIRTUAL_IP:-}" ]]; then
  iptables -t nat -D POSTROUTING -s "$HOTSPOT_SUBNET" -j SNAT --to-source "$VIRTUAL_IP" 2>/dev/null || true
  iptables -t mangle -D FORWARD -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "${MSS_VALUE:-1200}" 2>/dev/null || true
  iptables -D FORWARD -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -o "$HOTSPOT_IFACE" -d "$HOTSPOT_SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
fi

if [[ -n "${IFACE:-}" ]] && command -v resolvectl >/dev/null 2>&1; then
  resolvectl revert "$IFACE" 2>/dev/null || true
  resolvectl flush-caches 2>/dev/null || true
fi

if command -v nmcli >/dev/null 2>&1; then
  nmcli connection down "${NM_MARKER:-Surfshark IKEv2 (Connected)}" >/dev/null 2>&1 || true
  nmcli connection delete "${NM_MARKER:-Surfshark IKEv2 (Connected)}" >/dev/null 2>&1 || true
fi

rm -f "$STATE_FILE"
echo "Restricted Surfshark IKEv2 disconnected; hotspot VPN rules, Ubuntu marker and network overrides reverted."
