# Phase 5 — Android + iOS

This branch implements the native mobile VPN bridges used by the Flutter client.

## Android

- `VpnService`-based tunnel host
- Flutter `MethodChannel` bridge for prepare/connect/disconnect/status
- Foreground service notification
- Explicit rejection when VPN permission has not been granted
- WireGuard profile is read from app-private storage; secrets are not persisted in Flutter preferences

## iOS

- `NETunnelProviderManager` host bridge
- Packet Tunnel provider target
- WireGuardKit-based tunnel startup
- App-group shared container for ephemeral profile handoff
- Explicit failure if the required Network Extension entitlement or profile is unavailable

## Shared rules

- Flutter UI never reports `connected` before the native platform confirms startup.
- Private keys/passwords are not logged.
- Platform bridges expose a narrow command surface only.
- Mobile builds remain unsigned in CI; real-device VPN tests require Android/iOS signing identities and platform entitlements.
