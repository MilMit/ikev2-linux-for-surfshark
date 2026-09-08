# Flutter Migration Roadmap

The product name is intentionally temporary. The architecture must support multiple VPN providers from the beginning.

## Phase 1 — Flutter foundation and UI migration
- Add Flutter application beside the existing Tauri desktop client.
- Preserve the current client during migration as a functional reference.
- Rebuild UI as modular features instead of one large entry file.
- Establish responsive desktop/mobile layout, light/dark themes, navigation, localization, and state management.
- No provider-specific assumptions in UI models.

## Phase 2 — Shared core and provider abstraction
- Keep reusable Rust core functionality.
- Define stable Flutter/Rust FFI boundary.
- Add provider-neutral models for locations, endpoints, credentials, capabilities, connection state, diagnostics, and traffic stats.
- Introduce provider adapters; Surfshark becomes the first adapter rather than the product identity.

## Phase 3 — Protocol layer
- WireGuard, IKEv2, and OpenVPN abstractions.
- Auto protocol selection, timeout handling, fallback, endpoint rotation, reconnect, and health checks.

## Phase 4 — Desktop platform adapters
- Linux, Windows, and macOS native networking adapters.
- DNS handling, routing, kill switch, split tunneling, secure credential storage, and packaging.

## Phase 5 — Mobile platform adapters
- Android VpnService integration.
- iOS NetworkExtension integration.
- Background lifecycle, always-on/on-demand behavior where supported, app-based routing, and mobile packaging.

## Phase 6 — Production hardening and multi-provider release
- Add the second VPN provider before product naming is finalized.
- Bundled server catalog plus remote signed/validated updates and cache.
- Favorites, recents, fastest location, auto location, diagnostics, leak protection, network-change recovery, updates, signing, CI/CD, and release builds.

## Architectural rule

Flutter owns presentation and cross-platform application state. Rust owns reusable core logic. OS-native adapters own privileged networking behavior. VPN providers are plugins/adapters, not hard-coded product assumptions.
