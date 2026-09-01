# MilMit Secure — Protection Control Center

This document maps the useful ideas from the Waydroid VPN Router v5.3.9 reference package to the native strongSwan/XFRM Surfshark client. Android/Waydroid-specific machinery is intentionally not copied because this project owns the IKEv2 tunnel directly.

## Adopted in the native IKEv2 design

- Protection Health score with HEALTHY / DEGRADED / FAIL_CLOSED / UNPROTECTED states.
- Live topology: Device → Linux → XFRM → Surfshark → Internet.
- Persistent watchdog telemetry and bounded recovery.
- Last Known Good snapshot after successful protection.
- Protected speed test: connect time, TTFB, download throughput and compatibility recommendation.
- DNS evidence test without relying on a third-party DNS-leak webpage.
- Adaptive MTU/MSS probe.
- Route Tester for domain/IP/URL with Iran-cache awareness.
- Iran Direct + Foreign VPN policy routing.
- Per-hotspot-device VPN/Direct policy.
- Recent public destinations/candidates using passive host socket observation.
- Redacted support bundle that never includes VPN credentials.
- Emergency STOP EVERYTHING for MilMit-owned routing/XFRM state.
- Live RX/TX/latency in the dashboard/top bar.
- Professional operation monitor instead of blocking terminal-style flows.

## Next hardening layers before release

These are useful concepts from the reference package and belong in MilMit Secure, but require dedicated native implementations rather than copying Android/Waydroid code:

- Explicit routing priority: Block > Force VPN > Manual Direct > Iran Direct > profile default.
- Domain rules with DNS-aware ipsets and one-click candidate actions.
- Local-first rule snapshots with atomic update, checksum validation and Last Good fallback.
- Per-device Block/Pause, bandwidth limit and daily quota policies.
- Timed Guest Hotspot with random password/QR and fail-closed expiry.
- Client isolation for shared hotspot mode.
- IPv6 policy (block/protected/system) and optional QUIC block.
- Force-DNS / external-DNS block mode.
- Boot restore of Last Known Good with safe validation.
- Event timeline with grouping/filtering/archive.
- Local status portal restricted to loopback/hotspot subnets.
- Cached MTU fingerprint per endpoint/network for Performance / Balanced / Maximum Compatibility profiles.
- One-click Apply Safely / Full Live Test pipeline with staged diagnostics.

## UI/UX direction

The GTK4/libadwaita GUI is organized as a control center instead of a form:

1. Dashboard — animated connection orb, live throughput/latency/IP, protection health and topology.
2. Routing — credentials, VPN Everything/Iran Direct, Kill Switch, DNS and MSS tuning.
3. Devices — hotspot policy and visual device manager.
4. Protection Tools — speed/TTFB, DNS evidence, MTU/MSS, Route Tester, Last Known Good, support bundle and Emergency Stop.
5. Diagnostics — streaming operation monitor.

Animations remain lightweight: stack transitions, connection-state morphing, pulsing protected orb and non-blocking progress. Network diagnostics themselves never run on the GTK main thread.
