#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/apps/desktop"
cd "$APP"

if ! command -v npm >/dev/null 2>&1; then echo "npm is required for the new desktop UI." >&2; exit 1; fi
if ! command -v pkg-config >/dev/null 2>&1; then sudo apt-get update; sudo apt-get install -y pkg-config; fi
need_install=0
for module in webkit2gtk-4.1 libsoup-3.0 javascriptcoregtk-4.1; do pkg-config --exists "$module" || need_install=1; done
if ((need_install)); then
  echo "Installing/repairing required Tauri Linux build dependencies..."
  sudo apt-get update
  sudo apt-get install -y build-essential pkg-config libwebkit2gtk-4.1-dev libjavascriptcoregtk-4.1-dev libsoup-3.0-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev
fi
MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
pc_paths=("/usr/lib/pkgconfig" "/usr/share/pkgconfig"); [[ -n "$MULTIARCH" ]] && pc_paths=("/usr/lib/$MULTIARCH/pkgconfig" "${pc_paths[@]}")
for p in "${pc_paths[@]}"; do [[ -d "$p" ]] || continue; case ":${PKG_CONFIG_PATH:-}:" in *":$p:"*) ;; *) export PKG_CONFIG_PATH="$p${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" ;; esac; done
missing_modules=(); for module in webkit2gtk-4.1 libsoup-3.0 javascriptcoregtk-4.1; do pkg-config --exists "$module" || missing_modules+=("$module"); done
if ((${#missing_modules[@]})); then echo "ERROR: pkg-config still cannot find: ${missing_modules[*]}" >&2; echo "PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-<unset>}" >&2; exit 1; fi
echo "Tauri native dependencies detected:"; pkg-config --modversion webkit2gtk-4.1 libsoup-3.0 javascriptcoregtk-4.1

backend_changed=0
backend_files=(restricted-ikev2-connect.sh restricted-ikev2-connect-v2.sh restricted-ikev2-disconnect.sh connection-engine-v3.py secure-endpoint-discovery.py hotspot-device-policy.sh milmit-surfshark-watchdog.sh control-center.py router-features.py advanced-router.py rules-update.py status-portal.py desktop-features.py hotspot-doctor.py milmit-surfshark-sleep-hook.sh)
for f in "${backend_files[@]}"; do
  [[ -f "/usr/lib/milmit-surfshark/$f" ]] && cmp -s "$ROOT/scripts/$f" "/usr/lib/milmit-surfshark/$f" || backend_changed=1
done
[[ -f /usr/lib/milmit-surfshark/install-privileged-helper.sh ]] && cmp -s "$ROOT/scripts/install-privileged-helper.sh" /usr/lib/milmit-surfshark/install-privileged-helper.sh || backend_changed=1
[[ -f /usr/libexec/milmit-surfshark-helper ]] && cmp -s "$ROOT/scripts/milmit-surfshark-helper" /usr/libexec/milmit-surfshark-helper || backend_changed=1
[[ -f /etc/systemd/system/milmit-surfshark-autoconnect.service ]] && cmp -s "$ROOT/packaging/milmit-surfshark-autoconnect.service" /etc/systemd/system/milmit-surfshark-autoconnect.service || backend_changed=1
command -v ike-scan >/dev/null 2>&1 || backend_changed=1
if ((backend_changed)); then
  echo "Protected backend changed; installing the current backend and IKE readiness probe once..."
  pkexec /bin/bash "$ROOT/scripts/install-privileged-helper.sh"
fi

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "Installing SVG icon renderer once..."
  sudo apt-get update
  sudo apt-get install -y librsvg2-bin
fi
/bin/bash "$ROOT/scripts/prepare-tauri-icons.sh"

[ -d node_modules ] || npm install
exec npm run tauri dev
