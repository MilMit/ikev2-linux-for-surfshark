#!/bin/sh
set -e

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reset-failed >/dev/null 2>&1 || true
systemctl try-reload-or-restart polkit.service >/dev/null 2>&1 || true

# Debian policy keeps user data on ordinary remove/upgrade. A real purge removes
# credentials, counters and cached routing/rules as well.
if [ "${1:-}" = "purge" ]; then
  rm -rf /etc/milmit-surfshark /var/lib/milmit-surfshark /run/milmit-surfshark
  rm -f /var/log/milmit-surfshark-*.log
fi

exit 0
