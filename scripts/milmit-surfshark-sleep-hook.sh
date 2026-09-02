#!/usr/bin/env bash
set -u

STATE=/run/milmit-surfshark/restricted.state
MARKER=/run/milmit-surfshark/was-connected-before-sleep
ROUTER=/usr/lib/milmit-surfshark/router-features.py

case "${1:-}" in
  pre)
    if [[ -f "$STATE" && -e /sys/class/net/milmitxfrm0 ]]; then
      touch "$MARKER"
      chmod 0600 "$MARKER" 2>/dev/null || true
    else
      rm -f "$MARKER"
    fi
    ;;
  post)
    [[ -e "$MARKER" ]] || exit 0
    rm -f "$MARKER"
    # NetworkManager and Wi-Fi may need a moment after resume. Do not block the
    # system resume path; hand recovery back to the watchdog after a short delay.
    (
      sleep 3
      ip route flush cache >/dev/null 2>&1 || true
      command -v conntrack >/dev/null 2>&1 && conntrack -F >/dev/null 2>&1 || true
      [[ -x "$ROUTER" ]] && "$ROUTER" apply >/dev/null 2>&1 || true
      systemctl restart milmit-surfshark-watchdog.service >/dev/null 2>&1 || true
    ) &
    ;;
esac
exit 0
