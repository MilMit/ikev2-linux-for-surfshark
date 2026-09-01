#!/usr/bin/env bash
set -u

STATE=/run/milmit-surfshark/restricted.state
LIVE=/run/milmit-surfshark/live.state
HELPER=/usr/libexec/milmit-surfshark-helper
XFRM=milmitxfrm0
MARK=0x112
fail=0

ok() { printf '✓ %s\n' "$*"; }
warn() { printf '! %s\n' "$*"; }
bad() { printf '✗ %s\n' "$*"; fail=1; }

printf 'MilMit Surfshark IKEv2 self-test\n\n'

for cmd in swanctl ip iptables nmcli curl resolvectl; do
  command -v "$cmd" >/dev/null 2>&1 && ok "$cmd available" || bad "$cmd missing"
done
command -v ipset >/dev/null 2>&1 && ok 'ipset available (Iran Direct ready)' || warn 'ipset missing (VPN Everything still works)'

[[ -x "$HELPER" ]] && ok 'privileged helper installed' || bad 'privileged helper missing'
systemctl is-active --quiet milmit-surfshark-watchdog.service 2>/dev/null && ok 'watchdog service active' || bad 'watchdog service inactive'

if [[ -f "$STATE" ]]; then
  ok 'restricted VPN state exists'
  vip=$(awk -F= '$1=="VIRTUAL_IP"{print $2;exit}' "$STATE")
  pub=$(awk -F= '$1=="PUBLIC_IP"{print $2;exit}' "$STATE")
  mark=$(awk -F= '$1=="MARK_VPN"{print $2;exit}' "$STATE"); mark="${mark:-$MARK}"
  [[ -n "$vip" ]] && ok "virtual IP: $vip" || bad 'virtual IP missing'
  [[ -n "$pub" ]] && ok "recorded public IP: $pub" || bad 'public IP missing'
  swanctl --list-sas 2>/dev/null | grep -q 'milmit-surfshark-restricted.*ESTABLISHED' && ok 'IKE SA established' || bad 'IKE SA not established'
  ip link show "$XFRM" >/dev/null 2>&1 && ok 'XFRM interface exists' || bad 'XFRM interface missing'
  route=$(ip -4 route get 1.1.1.1 mark "$mark" 2>&1 || true)
  printf '%s\n' "$route" | grep -q "dev $XFRM" && ok 'marked Internet route selects XFRM VPN' || bad "marked route wrong: $route"
  actual=$(curl -4 --max-time 10 -sS https://api.ipify.org 2>/dev/null || true)
  [[ -n "$actual" ]] && ok "live public IP: $actual" || bad 'normal system curl cannot reach Internet'
  if [[ -n "$pub" && -n "$actual" && "$pub" == "$actual" ]]; then ok 'system traffic exits through recorded Surfshark IP'; else warn 'live IP differs from recorded VPN IP'; fi
else
  warn 'VPN is disconnected; connected-path checks skipped'
fi

if [[ -f "$LIVE" ]]; then
  health=$(awk -F= '$1=="HEALTH"{print $2;exit}' "$LIVE")
  rx=$(awk -F= '$1=="RX_BPS"{print $2;exit}' "$LIVE")
  tx=$(awk -F= '$1=="TX_BPS"{print $2;exit}' "$LIVE")
  latency=$(awk -F= '$1=="LATENCY_MS"{print $2;exit}' "$LIVE")
  ok "watchdog telemetry: health=${health:-unknown} rx=${rx:-0}B/s tx=${tx:-0}B/s latency=${latency:-0}ms"
else
  warn 'watchdog live telemetry file not present yet'
fi

printf '\nNetworkManager active connections:\n'
nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null || true

printf '\nPolicy rules:\n'
ip rule show 2>/dev/null | grep -E '0x112|0x113|lookup 220' || true

printf '\nResult: '
if [[ "$fail" == 0 ]]; then
  printf 'PASS (warnings may still need review)\n'
  exit 0
else
  printf 'FAIL\n'
  exit 1
fi
