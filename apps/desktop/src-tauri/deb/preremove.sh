#!/bin/sh
set -e

# Tear down the active MilMit datapath before package files disappear. This is
# intentionally best-effort so package removal cannot strand the user offline.
if [ -x /usr/libexec/milmit-surfshark-helper ]; then
  /usr/libexec/milmit-surfshark-helper emergency-stop >/dev/null 2>&1 || \
  /usr/libexec/milmit-surfshark-helper disconnect >/dev/null 2>&1 || true
fi

systemctl disable --now milmit-surfshark-autoconnect.service >/dev/null 2>&1 || true
systemctl disable --now milmit-surfshark-watchdog.service >/dev/null 2>&1 || true
systemctl disable --now milmit-surfshark-rules-update.timer >/dev/null 2>&1 || true
systemctl disable --now milmit-surfshark-portal.service >/dev/null 2>&1 || true
systemctl disable --now milmit-surfshark-keepawake.service >/dev/null 2>&1 || true

exit 0
