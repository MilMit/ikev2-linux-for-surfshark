# Flutter Linux Platform Adapter

Flutter now uses the same privileged Linux backend as the existing Tauri desktop application instead of maintaining a second VPN implementation.

## Runtime path

```text
Flutter
  -> Dart FFI
  -> milmit-vpn-flutter-ffi
  -> milmit-vpn-platform-linux
  -> pkexec /usr/libexec/milmit-surfshark-helper
  -> Connection Engine v3
  -> StrongSwan / WireGuard fallback / OpenVPN fallback
  -> routing, DNS protection, watchdog and kill-switch backend
```

## Implemented

- Real Linux `connect` through `engine-connect`.
- Non-blocking connection start; Flutter polls the existing engine state file.
- Real `disconnect` through the privileged helper.
- Connection state mapping from `/run/milmit-surfshark/engine-v3.json`.
- Public-IP state reading from `/run/milmit-surfshark/live.state` when available.
- Kill-switch/lockdown changes through the privileged helper.
- Backend capability diagnostics for StrongSwan, WireGuard, OpenVPN, credentials and helper installation.
- IPv4 candidate preference from the bundled catalog with DNS resolution only as a fallback.
- No fake success on non-Linux platforms while their platform adapters are still missing.

## Restricted-network requirement

A production bundled catalog should contain fallback IPv4 endpoints. If the catalog contains only hostnames and DNS/provider infrastructure is blocked before connection, the Linux adapter intentionally fails with a clear error instead of pretending to connect.

## Protocol behavior

`Auto` and `IKEv2` currently start Connection Engine v3. The existing engine can fall back to WireGuard/OpenVPN when matching root-only manual profiles are installed.

Explicit `WireGuard` and `OpenVPN` selection is not yet exposed by the privileged helper. The adapter checks whether the expected profile exists and reports the limitation rather than bypassing the root-owned networking design.

## DNS and IPv6

DNS and IPv6 leak protection are owned by the existing privileged connection engine/routing backend. Flutter preference state is preserved, but independent runtime on/off commands should only be exposed after the helper has dedicated validated commands for them.

## Build validation

Run from the repository root on Linux:

```bash
cargo check -p surfshark-ikev2-core
cargo check -p milmit-vpn-platform-linux
cargo check -p milmit-vpn-flutter-ffi
./scripts/build-flutter-ffi.sh
```

The Flutter FFI library must be packaged where `DynamicLibrary.open('libmilmit_vpn_flutter_ffi.so')` can resolve it.
