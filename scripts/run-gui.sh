#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER=/usr/libexec/milmit-surfshark-helper

if [[ ! -x "$HELPER" ]]; then
  echo "First-run setup: Ubuntu will ask for your password once to install the restricted VPN helper."
  /usr/bin/pkexec /usr/bin/bash "$ROOT/scripts/install-privileged-helper.sh"
fi

export PATH="$ROOT/scripts/pkexec-shim:$PATH"
cd "$ROOT"
exec cargo run -p surfshark-ikev2-gui
