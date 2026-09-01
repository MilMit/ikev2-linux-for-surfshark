# Tauri migration parity audit

This checklist compares the new `apps/desktop` Tauri/React client with the legacy GTK client and the existing MilMit privileged networking backend. It is intentionally strict: a screen or toggle is only marked complete when it is wired to real behavior, not when it merely renders.

## Connection and state

- [ ] Selected location controls the next VPN connection. Current Tauri connect still uses `quick-connect`, so it can reuse the last successful backend profile instead of the location currently selected in the UI.
- [ ] Restore live connection-state polling from `/run/milmit-surfshark/restricted.state` and `/run/milmit-surfshark/live.state` (connected/disconnected/reconnecting, public IP, exit country, live latency).
- [ ] Restore explicit connecting / reconnecting / disconnecting state transitions based on backend state rather than only local React state.
- [ ] Restore connection error details and verified disconnect state in the main UI.
- [x] Real Disconnect calls the privileged helper.
- [x] Manual disconnect protection is handled by the backend/watchdog marker.

## Location browser

- [x] Full location catalog from the existing Rust catalog.
- [x] Country grouping / expandable country rows.
- [x] Search by country, city and hostname.
- [x] Persistent Favorites.
- [x] Per-location latency shown in the location selector.
- [x] Latency uses bundled direct IPs where available, avoiding poisoned Surfshark DNS on restricted networks.
- [ ] Restore Recent locations list.
- [ ] Restore Fastest location action based on measured latency.
- [ ] Restore manual Scan all / rescan control and scan progress summary.
- [ ] Restore context actions: Select, Ping now, Favorite, Copy hostname.
- [ ] Restore richer latency diagnostics (multiple packets, packet loss and jitter) in addition to the quick one-packet selector scan.
- [ ] Add sort/filter controls such as latency, favorites and availability.

## VPN settings

- [ ] Restore editable MSS setting (legacy default 1200).
- [ ] Restore editable DNS servers.
- [ ] Restore Kill Switch control wired to backend settings.
- [ ] Restore Iran Direct routing toggle wired to backend settings.
- [ ] Restore Auto recovery setting wired to backend settings.
- [ ] Restore hotspot-via-VPN and hotspot interface settings.
- [ ] Restore secure Surfshark service-credential setup/status UI.
- [ ] Persist these settings in the same canonical configuration rather than keeping presentation-only toggles.

## Diagnostics

- [x] Health action.
- [x] Speed test action.
- [x] DNS test action.
- [x] MTU/MSS test action.
- [x] Full live verification action.
- [x] Support bundle action.
- [x] Rules status/update actions.
- [x] Route explain / route policy actions.
- [ ] Restore dedicated Ping Internet diagnostic.
- [ ] Restore dedicated Ping VPN endpoint diagnostic.
- [ ] Restore dedicated Ping selected location diagnostic.
- [ ] Restore packet loss + min/avg/max RTT + jitter report from the GTK client.
- [ ] Restore Save/inspect Last Known Good actions.
- [ ] Restore recent destinations/history views.

## Split tunneling and policy

- [x] Domain/IP/CIDR Direct / VPN / Block policy UI is wired to helper commands.
- [x] Route Explain is wired.
- [ ] Real Linux application-based split tunneling is not implemented yet; current page is informational only.
- [ ] Application discovery and per-app include/exclude UI.
- [ ] Persisted application rules and backend cgroup/mark routing.

## Hotspot and devices

- [x] Router status can be queried.
- [x] Guest hotspot Start / Stop / Status actions.
- [x] Hotspot repair action.
- [ ] Restore structured connected-device cards instead of raw router status text.
- [ ] Restore per-device VPN / Direct / Block / Pause controls.
- [ ] Restore per-device speed limit / quota / quota action controls.
- [ ] Restore Force DNS switch.
- [ ] Restore QUIC blocking switch.
- [ ] Restore client isolation switch.
- [ ] Restore IPv6 policy control.

## Advanced and Mullvad-style UX

- [ ] Auto-connect is not yet a real persisted startup behavior in Tauri.
- [ ] Launch at startup is not yet wired.
- [ ] Persistent Lockdown mode is not yet wired as a product setting.
- [ ] Custom location lists are not implemented; Favorites are real, arbitrary custom lists are not.
- [ ] Multi-hop equivalent is not implemented and must not be represented as a fake toggle.
- [ ] App notifications/toasts should be state-aware and auto-dismiss; current toast behavior is basic.
- [ ] Keyboard navigation, focus states, accessibility names and reduced-motion behavior need a full pass.
- [ ] Context menus and richer row interactions need parity with the previous location browser.

## Migration rule

Do not remove the legacy GTK client until every required item above is either complete in Tauri or explicitly declared intentionally out of scope. Backend capabilities should be reused rather than reimplemented in frontend JavaScript. Security-sensitive actions must continue through the root-owned validated helper allowlist.
