#!/usr/bin/env bash
set -euo pipefail

# Compatibility entrypoint. The GUI and older launchers may still call this
# filename, so always delegate to the auth/routing-fixed v2 backend.
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ -x /usr/lib/milmit-surfshark/restricted-ikev2-connect-v2.sh ]]; then
  exec /usr/lib/milmit-surfshark/restricted-ikev2-connect-v2.sh "$@"
fi

exec "$SELF_DIR/restricted-ikev2-connect-v2.sh" "$@"
