#!/usr/bin/env bash
set -u

STATE_DIR=/run/milmit-surfshark
STATE_FILE="$STATE_DIR/restricted.state"
LIVE_FILE="$STATE_DIR/live.state"
LAST_FILE=/var/lib/milmit-surfshark/last-profile.state
USAGE_FILE=/var/lib/milmit-surfshark/traffic-usage.state
DISCONNECTING="$STATE_DIR/disconnecting"
MANUAL_DISCONNECTED="$STATE_DIR/manual-disconnected"
RECOVERING="$STATE_DIR/watchdog-recovering"
CONNECT=/usr/lib/milmit-surfshark/restricted-ikev2-connect.sh
DISCONNECT=/usr/lib/milmit-surfshark/restricted-ikev2-disconnect.sh
ROUTER=/usr/lib/milmit-surfshark/router-features.py
DESKTOP=/usr/lib/milmit-surfshark/desktop-features.py
CRED_FILE=/etc/milmit-surfshark/credentials
XFRM_IF=milmitxfrm0
MARK_VPN=0x112
MARK_DIRECT=0x113

mkdir -p "$STATE_DIR" /var/lib/milmit-surfshark; chmod 0755 "$STATE_DIR" /var/lib/milmit-surfshark
state_get(){ local file="$1" key="$2"; [[ -f "$file" ]] || return 0; awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$file" 2>/dev/null || true; }
write_live(){ local health="$1" rx="$2" tx="$3" latency="$4" failures="$5" note="$6"; local tmp="${LIVE_FILE}.tmp"; cat >"$tmp" <<EOF
HEALTH=$health
RX_BPS=$rx
TX_BPS=$tx
LATENCY_MS=$latency
FAILURES=$failures
NOTE=$note
UPDATED=$(date +%s)
EOF
chmod 0644 "$tmp"; mv -f "$tmp" "$LIVE_FILE"; }
persist_profile(){ [[ -f "$STATE_FILE" ]] || return 0; local tmp="${LAST_FILE}.tmp"; cp "$STATE_FILE" "$tmp" 2>/dev/null || return 0; chmod 0600 "$tmp"; mv -f "$tmp" "$LAST_FILE"; }
usage_reset_session(){ [[ -f "$USAGE_FILE" ]] || return 0; local tmp="${USAGE_FILE}.tmp"; awk -F= 'BEGIN{OFS="="} $1=="LAST_RX"||$1=="LAST_TX"||$1=="LAST_DIRECT_RX"||$1=="LAST_DIRECT_TX"{$2=0} {print $1,$2}' "$USAGE_FILE" >"$tmp" 2>/dev/null || return 0; chmod 0644 "$tmp"; mv -f "$tmp" "$USAGE_FILE"; }
# XFRM counters already contain host traffic plus hotspot traffic sent through
# the VPN. Only hotspot traffic deliberately routed Direct bypasses XFRM, so we
# read just those FORWARD counters and add them to the persistent totals. This
# avoids double-counting VPN-routed hotspot clients.
direct_hotspot_counters(){
  local phys hot subnet dump line bytes up=0 down=0
  phys="$(state_get "$STATE_FILE" IFACE)"; hot="$(state_get "$STATE_FILE" HOTSPOT_IFACE)"; subnet="$(state_get "$STATE_FILE" HOTSPOT_SUBNET)"
  [[ -n "$phys" && -n "$hot" && -n "$subnet" ]] || { echo "0 0"; return; }
  dump="$(iptables-save -c -t filter 2>/dev/null || true)"
  while IFS= read -r line; do
    [[ "$line" == *"-A MILMIT_HOTSPOT_FWD"* ]] || continue
    [[ "$line" =~ ^\[([0-9]+):([0-9]+)\] ]] || continue; bytes="${BASH_REMATCH[2]}"
    if [[ "$line" == *"-i $hot"* && "$line" == *"-o $phys"* && "$line" == *"--mark $MARK_DIRECT"* ]]; then up=$((up+bytes)); fi
    if [[ "$line" == *"-i $phys"* && "$line" == *"-o $hot"* && "$line" == *"-d $subnet"* && "$line" == *"ESTABLISHED,RELATED"* ]]; then down=$((down+bytes)); fi
  done <<< "$dump"
  echo "$down $up"
}
update_usage(){
  local rx="$1" tx="$2" direct_rx="$3" direct_tx="$4" today month all_rx all_tx day day_rx day_tx mon mon_rx mon_tx last_rx last_tx last_direct_rx last_direct_tx dr=0 dt=0 ddr=0 ddt=0 tmp
  today="$(date +%F)"; month="$(date +%Y-%m)"
  all_rx="$(state_get "$USAGE_FILE" ALL_RX_BYTES)"; all_rx="${all_rx:-0}"; all_tx="$(state_get "$USAGE_FILE" ALL_TX_BYTES)"; all_tx="${all_tx:-0}"
  day="$(state_get "$USAGE_FILE" DAY)"; day_rx="$(state_get "$USAGE_FILE" DAY_RX_BYTES)"; day_rx="${day_rx:-0}"; day_tx="$(state_get "$USAGE_FILE" DAY_TX_BYTES)"; day_tx="${day_tx:-0}"
  mon="$(state_get "$USAGE_FILE" MONTH)"; mon_rx="$(state_get "$USAGE_FILE" MONTH_RX_BYTES)"; mon_rx="${mon_rx:-0}"; mon_tx="$(state_get "$USAGE_FILE" MONTH_TX_BYTES)"; mon_tx="${mon_tx:-0}"
  last_rx="$(state_get "$USAGE_FILE" LAST_RX)"; last_rx="${last_rx:-0}"; last_tx="$(state_get "$USAGE_FILE" LAST_TX)"; last_tx="${last_tx:-0}"
  last_direct_rx="$(state_get "$USAGE_FILE" LAST_DIRECT_RX)"; last_direct_rx="${last_direct_rx:-0}"; last_direct_tx="$(state_get "$USAGE_FILE" LAST_DIRECT_TX)"; last_direct_tx="${last_direct_tx:-0}"
  [[ "$day" == "$today" ]] || { day="$today"; day_rx=0; day_tx=0; }
  [[ "$mon" == "$month" ]] || { mon="$month"; mon_rx=0; mon_tx=0; }
  if ((last_rx>0 && rx>=last_rx)); then dr=$((rx-last_rx)); fi
  if ((last_tx>0 && tx>=last_tx)); then dt=$((tx-last_tx)); fi
  if ((last_direct_rx>0)); then if ((direct_rx>=last_direct_rx)); then ddr=$((direct_rx-last_direct_rx)); else ddr=$direct_rx; fi; fi
  if ((last_direct_tx>0)); then if ((direct_tx>=last_direct_tx)); then ddt=$((direct_tx-last_direct_tx)); else ddt=$direct_tx; fi; fi
  all_rx=$((all_rx+dr+ddr)); all_tx=$((all_tx+dt+ddt)); day_rx=$((day_rx+dr+ddr)); day_tx=$((day_tx+dt+ddt)); mon_rx=$((mon_rx+dr+ddr)); mon_tx=$((mon_tx+dt+ddt))
  tmp="${USAGE_FILE}.tmp"; cat >"$tmp" <<EOF
ALL_RX_BYTES=$all_rx
ALL_TX_BYTES=$all_tx
DAY=$day
DAY_RX_BYTES=$day_rx
DAY_TX_BYTES=$day_tx
MONTH=$mon
MONTH_RX_BYTES=$mon_rx
MONTH_TX_BYTES=$mon_tx
LAST_RX=$rx
LAST_TX=$tx
LAST_DIRECT_RX=$direct_rx
LAST_DIRECT_TX=$direct_tx
UPDATED=$(date +%s)
EOF
  chmod 0644 "$tmp"; mv -f "$tmp" "$USAGE_FILE"
}
apply_lockdown(){ [[ -x "$DESKTOP" ]] && "$DESKTOP" lockdown-apply >/dev/null 2>&1 || true; }
quick_reconnect(){
  [[ -x "$CONNECT" && -f "$LAST_FILE" && -f "$CRED_FILE" ]] || return 1
  [[ ! -e "$DISCONNECTING" && ! -e "$RECOVERING" && ! -e "$MANUAL_DISCONNECTED" ]] || return 1
  touch "$RECOVERING"
  local endpoint username mss dns hotspot recover hotspot_iface kill mode vpn_macs direct_macs rc
  endpoint="$(state_get "$LAST_FILE" SERVER_IP)"; mss="$(state_get "$LAST_FILE" MSS_VALUE)"; mss="${mss:-1200}"; dns="$(state_get "$LAST_FILE" DNS_CSV)"; dns="${dns:-162.252.172.57,149.154.159.92}"
  hotspot="$(state_get "$LAST_FILE" HOTSPOT_VPN)"; hotspot="${hotspot:-1}"; recover="$(state_get "$LAST_FILE" RECOVER_NETWORK)"; recover="${recover:-1}"; hotspot_iface="$(state_get "$LAST_FILE" HOTSPOT_IFACE_REQUEST)"; hotspot_iface="${hotspot_iface:-auto}"
  kill="$(state_get "$LAST_FILE" KILL_SWITCH)"; kill="${kill:-1}"; mode="$(state_get "$LAST_FILE" ROUTING_MODE)"; mode="${mode:-vpn_all}"; vpn_macs="$(state_get "$LAST_FILE" HOTSPOT_VPN_MACS)"; direct_macs="$(state_get "$LAST_FILE" HOTSPOT_DIRECT_MACS)"
  source "$CRED_FILE"; username="${SERVICE_USER:-}"
  if [[ -z "$endpoint" || -z "$username" ]]; then rm -f "$RECOVERING"; return 1; fi
  MILMIT_DISCONNECT_REASON=watchdog "$DISCONNECT" >/var/log/milmit-surfshark-watchdog.log 2>&1 || true; sleep 2
  "$CONNECT" "$endpoint" "$username" "$mss" "$dns" "$hotspot" "$recover" "$hotspot_iface" "$kill" "$mode" "$vpn_macs" "$direct_macs" </dev/null >>/var/log/milmit-surfshark-watchdog.log 2>&1
  rc=$?; rm -f "$RECOVERING"; apply_lockdown; return "$rc"
}

prev_rx=0; prev_tx=0; prev_ts=$(date +%s); failures=0; maintenance_tick=0
while true; do
  sleep 3; now=$(date +%s); maintenance_tick=$((maintenance_tick+1))
  if [[ -e "$MANUAL_DISCONNECTED" && ! -f "$STATE_FILE" ]]; then failures=0; prev_rx=0; prev_tx=0; prev_ts=$now; usage_reset_session; apply_lockdown; write_live DISCONNECTED 0 0 0 0 manual-disconnect; continue; fi
  if [[ -e "$MANUAL_DISCONNECTED" && -f "$STATE_FILE" && -e "/sys/class/net/$XFRM_IF" ]]; then rm -f "$MANUAL_DISCONNECTED"; fi
  if [[ ! -f "$STATE_FILE" ]]; then failures=0; prev_rx=0; prev_tx=0; prev_ts=$now; usage_reset_session; apply_lockdown; write_live DISCONNECTED 0 0 0 0 idle; continue; fi
  apply_lockdown; persist_profile
  vip="$(state_get "$STATE_FILE" VIRTUAL_IP)"; mark="$(state_get "$STATE_FILE" MARK_VPN)"; mark="${mark:-$MARK_VPN}"
  rx=$(cat "/sys/class/net/$XFRM_IF/statistics/rx_bytes" 2>/dev/null || echo 0); tx=$(cat "/sys/class/net/$XFRM_IF/statistics/tx_bytes" 2>/dev/null || echo 0); dt=$((now-prev_ts)); ((dt>0)) || dt=1
  if ((prev_rx>0 && rx>=prev_rx)); then rx_bps=$(((rx-prev_rx)/dt)); else rx_bps=0; fi
  if ((prev_tx>0 && tx>=prev_tx)); then tx_bps=$(((tx-prev_tx)/dt)); else tx_bps=0; fi
  prev_rx=$rx; prev_tx=$tx; prev_ts=$now
  read -r direct_rx direct_tx <<< "$(direct_hotspot_counters)"; direct_rx="${direct_rx:-0}"; direct_tx="${direct_tx:-0}"
  update_usage "$rx" "$tx" "$direct_rx" "$direct_tx"
  sa_ok=0; swanctl --list-sas 2>/dev/null | grep -q 'milmit-surfshark-restricted.*ESTABLISHED' && sa_ok=1
  route_ok=0; ip -4 route get 1.1.1.1 2>/dev/null | grep -q "dev $XFRM_IF" && route_ok=1
  latency=0; ping_line=$(ping -n -c 1 -W 1 1.1.1.1 2>/dev/null | grep -oE 'time=[0-9.]+' | head -n1 || true); [[ -n "$ping_line" ]] && latency="${ping_line#time=}"
  if ((maintenance_tick>=10)); then maintenance_tick=0; if [[ -x "$ROUTER" ]]; then "$ROUTER" quota-enforce >>/var/log/milmit-surfshark-watchdog.log 2>&1 || true; "$ROUTER" apply >>/var/log/milmit-surfshark-watchdog.log 2>&1 || true; fi; fi
  if [[ "$sa_ok" == 1 && "$route_ok" == 1 && -n "$vip" ]]; then failures=0; write_live OK "$rx_bps" "$tx_bps" "$latency" 0 protected
  else failures=$((failures+1)); write_live DEGRADED "$rx_bps" "$tx_bps" "$latency" "$failures" "sa=$sa_ok route=$route_ok"; if ((failures>=3)) && [[ ! -e "$DISCONNECTING" && ! -e "$MANUAL_DISCONNECTED" ]]; then write_live RECOVERING "$rx_bps" "$tx_bps" "$latency" "$failures" auto-reconnect; if quick_reconnect; then failures=0; else sleep 5; fi; fi; fi
done