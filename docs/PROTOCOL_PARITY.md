# VPN Protocol Parity

Branch: `phase-6-protocol-parity`

The Flutter product exposes the same protocol set on every supported platform:

- `WireGuard`
- `IKEv2`
- `OpenVPN`
- `Auto` with preference order `WireGuard -> IKEv2 -> OpenVPN`

## Platform matrix

| Platform | WireGuard | IKEv2 | OpenVPN | Auto |
| --- | --- | --- | --- | --- |
| Linux | native/helper WireGuard | strongSwan IKEv2 | OpenVPN helper | shared ordered fallback |
| Windows | WireGuard for Windows | Windows RAS/IKEv2 | OpenVPN | shared ordered fallback |
| macOS | WireGuardKit Network Extension | Apple Personal VPN / IKEv2 | OpenVPNAdapter Network Extension | native ordered fallback |
| Android | WireGuard GoBackend | Android VpnManager IKEv2 (API 30+) | embedded OpenVPN engine | native ordered fallback |
| iOS | WireGuardKit Network Extension | Apple Personal VPN / IKEv2 | OpenVPNAdapter Network Extension | native ordered fallback |

## Important runtime requirements

Protocol parity means each protocol has a real execution path. A successful real VPN connection still requires valid provider configuration.

### WireGuard

A valid WireGuard profile must exist for the selected server. Mobile profiles are private application data; Apple platforms use the application support/app-group location used by the native bridge.

### IKEv2

Service credentials must be saved securely. Android uses Android Keystore-backed encrypted storage. Apple platforms use Keychain. Windows/Linux retain their native/helper credential/profile provisioning model.

Android platform IKEv2 uses `VpnManager` and therefore requires Android 11 / API 30 or newer plus the platform IPsec tunnel feature. Older Android releases can still use WireGuard or OpenVPN.

### OpenVPN

A valid `.ovpn` profile must be provisioned for the selected server. Android embeds the OpenVPN-for-Android engine. Apple platforms use a Packet Tunnel Network Extension backed by OpenVPNAdapter/OpenVPN3.

## Licensing note

OpenVPN engine integrations are copyleft components. Android's embedded OpenVPN-for-Android integration and the Apple OpenVPN adapter have license obligations that must be reviewed before distributing production binaries. Do not publish binaries without including the required notices/source offer or otherwise satisfying the applicable licenses.

## Apple signing

Network Extension and Personal VPN capabilities require valid Apple provisioning/signing entitlements for production/device execution. CI can compile unsigned extension binaries, but an unsigned build cannot prove device-level VPN permission or App Store provisioning.

## Provider data caveat

The repository's bundled Surfshark catalog still contains placeholder seed endpoint data. Protocol engine completion must not be confused with a validated live Surfshark session. Before end-to-end testing, provision real legally redistributable server data and valid protocol profiles/credentials.

## Validation checklist

For each platform and each protocol, verify:

1. native permission/provisioning prompt succeeds;
2. connection reaches `connected`;
3. public IP changes to the VPN endpoint;
4. DNS and IPv6 leak checks pass according to enabled policy;
5. disconnect removes the tunnel and routes cleanly;
6. `Auto` selects WireGuard first and moves to IKEv2/OpenVPN when setup of the preferred engine is unavailable or rejected;
7. suspend/resume and network changes do not leave stale routes or credentials in logs.
