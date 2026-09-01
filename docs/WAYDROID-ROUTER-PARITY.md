# MilMit Secure — native router feature parity

The original Waydroid VPN Router package is used as a product/architecture reference only. MilMit Secure implements the useful network-control features natively around strongSwan IKEv2 + XFRM; Android/Waydroid-specific lifecycle and VpnService discovery are intentionally not copied because they do not apply to a native Linux IKEv2 client.

## Implemented native controls

- Transactional-style **Apply Safely** with snapshot, live route/HTTPS verification and advanced-hook rollback.
- **Last Known Good** profile, watchdog auto-recovery and Emergency Stop.
- Policy order: **Block > Force VPN > Manual Direct > Iran Direct > profile default**.
- Domain / hostname / IPv4 / CIDR policies with VPN, Direct and Block actions.
- **Iran Direct** with a local Chocolate4U rule snapshot; no remote fetch on the routing hot path.
- Validated/atomic Chocolate4U updater with GitHub + jsDelivr mirrors, SHA-256 validation for DAT assets and a weekly systemd timer.
- Route tester + route explain output.
- Recent destination / bypass candidate feed from `ss` and optional `conntrack`, with one-click-equivalent Direct / VPN / Block / Dismiss helper actions.
- Per-device VPN / Direct / Block / Pause controls.
- Per-device speed shaping with `tc` and daily quota actions: Notify / Throttle / Block.
- Hotspot forwarding, XFRM SNAT, return traffic, DNS redirect, repair and watchdog re-apply.
- Force DNS, QUIC blocking, IPv6 hotspot policy and client isolation.
- Timed Guest Hotspot with random password and Wi-Fi URI; QR support dependency is installed when available.
- Protection Health, protected speed/TTFB test, DNS evidence, MTU/MSS probe and full live test.
- Redacted support bundle and event history.
- Local status portal on TCP 8787, access-limited to loopback/current hotspot/active guest clients.
- Low-power controls and an opt-in systemd sleep inhibitor for long-running hotspot routing.
- GNOME indicator/tray, animated GTK/libadwaita dashboard and the advanced visual Hotspot Device Manager.

## Main helper commands

```bash
pkexec /usr/libexec/milmit-surfshark-helper apply-safe
pkexec /usr/libexec/milmit-surfshark-helper full-live-test
pkexec /usr/libexec/milmit-surfshark-helper router-status
pkexec /usr/libexec/milmit-surfshark-helper hotspot-repair
pkexec /usr/libexec/milmit-surfshark-helper candidates
pkexec /usr/libexec/milmit-surfshark-helper candidate-action 1.2.3.4 direct
pkexec /usr/libexec/milmit-surfshark-helper route-explain example.com
pkexec /usr/libexec/milmit-surfshark-helper rules-status
pkexec /usr/libexec/milmit-surfshark-helper rules-update
pkexec /usr/libexec/milmit-surfshark-helper guest-start 60 "MilMit Guest"
pkexec /usr/libexec/milmit-surfshark-helper emergency-stop
```

## Intentionally not ported

Waydroid container/session startup, Android package discovery, Android VpnService/TUN discovery, Android animation/Doze controls and Android app split-tunneling are not applicable to this project. Equivalent Linux-native controls should be implemented only where they make sense for strongSwan/XFRM.
