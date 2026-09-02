# MilMit Secure Connection Engine v3

Connection Engine v3 owns connection attempts instead of letting the desktop UI loop over endpoints.

## State machine

`PREPARING -> IKE -> AUTHENTICATING -> TUNNEL_ESTABLISHED -> VERIFYING_DATA -> CONNECTED`

When every IKEv2 candidate fails, the engine enters `FALLBACK`. If all IKE control channels establish successfully but return no decrypted tunnel traffic, the terminal state is `BLOCKED` instead of a misleading generic offline error.

Runtime state: `/run/milmit-surfshark/engine-v3.json`
Runtime events: `/run/milmit-surfshark/engine-v3.events`
Endpoint history: `/var/lib/milmit-surfshark/endpoint-health.json`
Last known good transport: `/var/lib/milmit-surfshark/lkg-v3.json`

## Endpoint health and Last Known Good

Successful endpoints receive a positive score and are tried before repeatedly failing endpoints. The last known good endpoint receives the highest preference for the same server identity. `DATA_PATH_BLOCKED` is tracked separately from authentication and handshake failures.

## Cancel

The desktop sends `cancel-connect` to the root-owned helper. The helper stops the current engine/connector workers and clears partial tunnel state. The UI remains asynchronous and can select another location while cleanup completes.

## Protocol fallback

IKEv2 direct-IP remains the primary transport. WireGuard and OpenVPN fallback support is built into the engine, but a matching Surfshark manual profile must exist locally because those protocols require provider-issued configuration/key material that cannot be derived safely from IKEv2 service credentials alone.

Matching profile paths use the Surfshark server identity as the basename:

- WireGuard: `/etc/milmit-surfshark/wireguard/<server-identity>.conf`
- OpenVPN: `/etc/milmit-surfshark/openvpn/<server-identity>.ovpn`

Example for Istanbul:

- `/etc/milmit-surfshark/wireguard/tr-ist.prod.surfshark.com.conf`
- `/etc/milmit-surfshark/openvpn/tr-ist.prod.surfshark.com.ovpn`

The installer creates these directories root-only (`0700`) and installs `wireguard-tools` and `openvpn` on Debian/Ubuntu when available.

## Diagnostics

`/usr/libexec/milmit-surfshark-helper engine-status` returns the current state, endpoint health, last-known-good transport and configured fallback profile availability as JSON.
