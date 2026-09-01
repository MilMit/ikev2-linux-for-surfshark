#!/usr/bin/env bash
set -u

STATE_DIR=/run/milmit-surfshark
STATE_FILE="$STATE_DIR/restricted.state"
LIVE_FILE="$STATE_DIR/live.state"
LAST_FILE=/var/lib/milmit-surfshark/last-profile.state
DISCONNECTING="$STATE_DIR/disconnecting"
RECOVERING="$STATE_DIR/watchdog-recovering"
CONNECT=/usr/lib/milmit-surfshark/restricted-ikev2-connect.sh
DISCONNECT=/usr/lib/milmit-surfshark/restricted-ikev2-disconnect.sh
CRED_FILE=/etc/milmit-surfshark/credentials
XFRM_IF=milmitxfrm0
MARK_VPN=0x112

mkdir -p "$STATE_DIR" /var/lib/milmit-surfshark
chmod 0755 "$STATE_DIR" /var/lib/milmit-surfshark

state_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$file" 2>/dev/null || true
}

write_live() {
  local health="$1" rx="$2" tx="$3" latency="$4" failures="$5" note="$6"
  local tmp="${LIVE_FILE}.tmp"
  cat >"$tmp" <<EOF
HEALTH=$health
RX_BPS=$rx
TX_BPS=$tx
LATENCY_MS=$latency
FAILURES=$failures
NOTE=$note
UPDATED=$(date +%s)
EOF
  chmod 0644 "$tmp"
  mv -f "$tmp" "$LIVE_FILE"
}

persist_profile() {
  [[ -f "$STATE_FILE" ]] || return 0
  local tmp="${LAST_FILE}.tmp"
  cp "$STATE_FILE" "$tmp" 2>/dev/null || return 0
  chmod 0600 "$tmp"
  mv -f "$tmp" "$LAST_FILE"
}

quick_reconnect() {
  [[ -x "$CONNECT" && -f "$LAST_FILE" && -f "$CRED_FILE" ]] || return 1
  [[ ! -e "$DISCONNECTING" && ! -e "$RECOVERING" ]] || return 1
  touch "$RECOVERING"

  local endpoint username mss dns hotspot recover hotspot_iface kill mode vpn_macs direct_macs rc
  endpoint="$(state_get "$LAST_FILE" SERVER_IP)"
  mss="$(state_get "$LAST_FILE" MSS_VALUE)"; mss="${mss:-1200}"
  dns="$(state_get "$LAST_FILE" DNS_CSV)"; dns="${dns:-162.252.172.57,149.154.159.92}"
  hotspot="$(state_get "$LAST_FILE" HOTSPOT_VPN)"; hotspot="${hotspot:-1}"
  recover="$(state_get "$LAST_FILE" RECOVER_NETWORK)"; recover="${recover:-1}"
  hotspot_iface="$(state_get "$LAST_FILE" HOTSPOT_IFACE_REQUEST)"; hotspot_iface="${hotspot_iface:-auto}"
  kill="$(state_get "$LAST_FILE" KILL_SWITCH)"; kill="${kill:-1}"
  mode="$(state_get "$LAST_FILE" ROUTING_MODE)"; mode="${mode:-vpn_all}"
  vpn_macs="$(state_get "$LAST_FILE" HOTSPOT_VPN_MACS)"
  direct_macs="$(state_get "$LAST_FILE" HOTSPOT_DIRECT_MACS)"
  # root-only file written with printf %q by the connect helper.
  # shellcheck disable=SC1090
  source "$CRED_FILE"
  username="${SERVICE_USER:-}"
  if [[ -z "$endpoint" || -z "$username" ]]; then
    rm -f "$RECOVERING"
    return 1
  fi

  "$DISCONNECT" >/var/log/milmit-surfshark-watchdog.log 2>&1 || true
  sleep 2
  "$CONNECT" "$endpoint" "$username" "$mss" "$dns" "$hotspot" "$recover" "$hotspot_iface" "$kill" "$mode" "$vpn_macs" "$direct_macs" </dev/null >>/var/log/milmit-surfshark-watchdog.log 2>&1
  rc=$?
  rm -f "$RECOVERING"
  return "$rc"
}

prev_rx=0
prev_tx=0
prev_ts=$(date +%s)
failures=0

while true; do
  sleep 3
  now=$(date +%s)
  if [[ ! -f "$STATE_FILE" ]]; then
    failures=0
    prev_rx=0; prev_tx=0; prev_ts=$now
    write_live DISCONNECTED 0 0 0 0 idle
    continue
  fi

  persist_profile
  vip="$(state_get "$STATE_FILE" VIRTUAL_IP)"
  mark="$(state_get "$STATE_FILE" MARK_VPN)"; mark="${mark:-$MARK_VPN}"

  rx=$(cat "/sys/class/net/$XFRM_IF/statistics/rx_bytes" 2>/dev/null || echo 0)
  tx=$(cat "/sys/class/net/$XFRM_IF/statistics/tx_bytes" 2>/dev/null || echo 0)
  dt=$(( now - prev_ts )); (( dt > 0 )) || dt=1
  if (( prev_rx > 0 && rx >= prev_rx )); then rx_bps=$(( (rx - prev_rx) / dt )); else rx_bps=0; fi
  if (( prev_tx > 0 && tx >= prev_tx )); then tx_bps=$(( (tx - prev_tx) / dt )); else tx_bps=0; fi
  prev_rx=$rx; prev_tx=$tx; prev_ts=$now

  sa_ok=0
  swanctl --list-sas 2>/dev/null | grep -q 'milmit-surfshark-restricted.*ESTABLISHED' && sa_ok=1
  route_ok=0
  ip -4 route get 1.1.1.1 mark "$mark" 2>/dev/null | grep -q "dev $XFRM_IF" && route_ok=1

  latency=0
  mark_dec=$((mark))
  ping_line=$(ping -n -c 1 -W 1 -m "$mark_dec" 1.1.1.1 2>/dev/null | grep -oE 'time=[0-9.]+' | head -n1 || true)
  [[ -n "$ping_line" ]] && latency="${ping_line#time=}"

  if [[ "$sa_ok" == 1 && "$route_ok" == 1 && -n "$vip" ]]; then
    failures=0
    write_live OK "$rx_bps" "$tx_bps" "$latency" 0 protected
  else
    failures=$((failures + 1))
    write_live DEGRADED "$rx_bps" "$tx_bps" "$latency" "$failures" "sa=$sa_ok route=$route_ok"
    if (( failures >= 3 )) && [[ ! -e "$DISCONNECTING" ]]; then
      write_live RECOVERING "$rx_bps" "$tx_bps" "$latency" "$failures" auto-reconnect
      if quick_reconnect; then
        failures=0
      else
        sleep 5
      fi
    fi
  fi
done
