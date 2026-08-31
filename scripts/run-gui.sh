#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER=/usr/libexec/milmit-surfshark-helper
INSTALLED_CONNECT=/usr/lib/milmit-surfshark/restricted-ikev2-connect.sh
INSTALLED_DISCONNECT=/usr/lib/milmit-surfshark/restricted-ikev2-disconnect.sh
SHIM="$ROOT/scripts/pkexec-shim/pkexec"

# GitHub Contents API does not preserve executable mode for newly-added files,
# so make the user-owned shim executable before putting it on PATH.
chmod 0755 "$SHIM"

needs_install=0
if [[ ! -x "$HELPER" || ! -f "$INSTALLED_CONNECT" || ! -f "$INSTALLED_DISCONNECT" ]]; then
  needs_install=1
elif ! cmp -s "$ROOT/scripts/restricted-ikev2-connect.sh" "$INSTALLED_CONNECT"; then
  needs_install=1
elif ! cmp -s "$ROOT/scripts/restricted-ikev2-disconnect.sh" "$INSTALLED_DISCONNECT"; then
  needs_install=1
elif ! cmp -s "$ROOT/scripts/milmit-surfshark-helper" "$HELPER"; then
  needs_install=1
fi

if [[ "$needs_install" == 1 ]]; then
  echo "VPN helper install/update: Ubuntu may ask for your password once."
  /usr/bin/pkexec /usr/bin/bash "$ROOT/scripts/install-privileged-helper.sh"
fi

export PATH="$ROOT/scripts/pkexec-shim:$PATH"
cd "$ROOT"
exec cargo run -p surfshark-ikev2-gui
