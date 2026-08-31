#!/usr/bin/env bash
set -euo pipefail

CONN_NAME=milmit-surfshark-restricted
STATE_FILE=/run/milmit-surfshark/restricted.state
NM_MARKER="Surfshark IKEv2 (Connected)"
HOTSPOT_RULE_PREF=17990

if [[ $EUID -ne 0 ]]; then echo "This helper must run as root." >&2; exit 77; fi

state_get() {
  local key="$1"
  [[ -f "$STATE_FILE" ]] || return 0
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$STATE_FILE" 2>/dev/null || true
}

VIRTUAL_IP="$(state_get VIRTUAL_IP)"
IFACE="$(state_get IFACE)"
MSS_VALUE="$(state_get MSS_VALUE)"
HOTSPOT_IFACE="$(state_get HOTSPOT_IFACE)"
HOTSPOT_SUBNET="$(state_get HOTSPOT_SUBNET)"
HOTSPOT_DNS="$(state_get HOTSPOT_DNS)"
RECOVER_NETWORK="$(state_get RECOVER_NETWORK)"

swanctl --terminate --ike "$CONN_NAME" >/dev/null 2>&1 || true
swanctl --terminate --ike surfshark-tr >/dev/null 2>&1 || true

if [[ -n "$VIRTUAL_IP" ]]; then
  iptables -t mangle -D OUTPUT -s "$VIRTUAL_IP/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "${MSS_VALUE:-1200}" 2>/dev/null || true
fi

if [[ -n "$HOTSPOT_SUBNET" ]]; then
  while ip rule del pref "$HOTSPOT_RULE_PREF" from "$HOTSPOT_SUBNET" lookup 220 >/dev/null 2>&1; do :; done

  if [[ -n "$VIRTUAL_IP" ]]; then
    while iptables -t nat -D POSTROUTING -s "$HOTSPOT_SUBNET" -j SNAT --to-source "$VIRTUAL_IP" 2>/dev/null; do :; done
  fi

  if [[ -n "$HOTSPOT_IFACE" ]]; then
    while iptables -t mangle -D FORWARD -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "${MSS_VALUE:-1200}" 2>/dev/null; do :; done
    while iptables -D FORWARD -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -o "$HOTSPOT_IFACE" -d "$HOTSPOT_SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done

    if [[ -n "$HOTSPOT_DNS" ]]; then
      while iptables -t nat -D PREROUTING -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -p udp --dport 53 -j DNAT --to-destination "$HOTSPOT_DNS" 2>/dev/null; do :; done
      while iptables -t nat -D PREROUTING -i "$HOTSPOT_IFACE" -s "$HOTSPOT_SUBNET" -p tcp --dport 53 -j DNAT --to-destination "$HOTSPOT_DNS" 2>/dev/null; do :; done
    fi
  fi
fi

# Remove only strongSwan routes that explicitly reference this app's virtual IP.
if [[ -n "$VIRTUAL_IP" ]]; then
  while IFS= read -r route; do
    [[ "$route" == *"src $VIRTUAL_IP"* ]] || continue
    # shellcheck disable=SC2086
    ip route del table 220 $route >/dev/null 2>&1 || true
  done < <(ip route show table 220 2>/dev/null || true)
fi
ip route flush cache >/dev/null 2>&1 || true

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

  # First try a non-disruptive reapply. If the physical link still cannot reach
  # the Internet, automatically do the same disconnect/connect cycle the user
  # previously had to perform manually.
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
echo "Restricted Surfshark IKEv2 disconnected. VPN DNS, hotspot policy routing/NAT, table-220 routes, virtual IP and physical-link state were restored."
