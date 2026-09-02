#!/bin/sh
set -e

# Debian maintainer script for MilMit Secure. Files are already unpacked by dpkg;
# this script only activates the privileged backend safely.
install -d -m 0755 /var/lib/milmit-surfshark /var/lib/milmit-surfshark/rules /run/milmit-surfshark
install -d -o root -g root -m 0700 /etc/milmit-surfshark /etc/milmit-surfshark/openvpn /etc/milmit-surfshark/wireguard
chmod 0755 /var/lib/milmit-surfshark /var/lib/milmit-surfshark/rules /run/milmit-surfshark

chmod 0755 /usr/libexec/milmit-surfshark-helper 2>/dev/null || true
find /usr/lib/milmit-surfshark -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod 0755 {} + 2>/dev/null || true

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable milmit-surfshark-watchdog.service >/dev/null 2>&1 || true
systemctl restart milmit-surfshark-watchdog.service >/dev/null 2>&1 || true
systemctl enable --now milmit-surfshark-rules-update.timer >/dev/null 2>&1 || true
systemctl enable --now milmit-surfshark-portal.service >/dev/null 2>&1 || true
systemctl disable --now milmit-surfshark-keepawake.service >/dev/null 2>&1 || true

if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database /usr/share/applications >/dev/null 2>&1 || true; fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor >/dev/null 2>&1 || true; fi

if [ -f /var/lib/milmit-surfshark/desktop-features.json ] && grep -q '"auto_connect"[[:space:]]*:[[:space:]]*true' /var/lib/milmit-surfshark/desktop-features.json; then
  systemctl enable milmit-surfshark-autoconnect.service >/dev/null 2>&1 || true
else
  systemctl disable milmit-surfshark-autoconnect.service >/dev/null 2>&1 || true
fi

systemctl try-reload-or-restart polkit.service >/dev/null 2>&1 || true
if [ ! -s /var/lib/milmit-surfshark/rules/ircidr.txt ] && [ -x /usr/lib/milmit-surfshark/rules-update.py ]; then /usr/lib/milmit-surfshark/rules-update.py update >/var/log/milmit-surfshark-rules-update.log 2>&1 || true; fi
if [ -x /usr/lib/milmit-surfshark/desktop-features.py ]; then /usr/lib/milmit-surfshark/desktop-features.py lockdown-apply >/dev/null 2>&1 || true; fi
exit 0
