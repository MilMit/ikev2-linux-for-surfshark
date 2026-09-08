# Server catalog architecture

The app must be able to start and connect without depending on a live provider API.

## Resolution order

For each provider the runtime chooses the best valid catalog in this order:

1. validated cache, when its revision is at least as new as the bundled revision;
2. validated bundled catalog shipped with the app.

A failed remote update never deletes the last known-good cache.

## Catalog envelope

Each catalog contains:

- `schema_version`
- monotonic `revision`
- `generated_at`
- provider metadata and locations
- `payload_sha256`
- optional `signature` object for remote catalogs

The signature object uses:

```json
{
  "key_id": "release-1",
  "algorithm": "ed25519",
  "signature_base64": "..."
}
```

The Rust core validates schema version, provider identity, required location fields, supported IKE ports, revision monotonicity, SHA-256 integrity, and Ed25519 authenticity before accepting a remote catalog.

Bundled catalogs are trusted as application resources and may remain unsigned. Remote catalogs are rejected unless a trusted Ed25519 public key is compiled into the native library.

## Signing keys

Never commit a catalog private key to this repository.

The FFI library reads the public verification key at compile time:

```bash
export VPN_CATALOG_ED25519_KEY_ID=release-1
export VPN_CATALOG_ED25519_PUBLIC_KEY_HEX=<64-hex-character-ed25519-public-key>
./scripts/build-flutter-ffi.sh
```

If the public key is not configured, remote catalog updates fail closed with `catalog_signing_key_not_configured`; bundled and previously valid cache data remain usable.

For key rotation, ship a new application release containing the next trusted public key before switching the catalog signer. Do not reuse or distribute the private key with the application.

## Multiple mirrors

Flutter can be built with multiple catalog mirrors. Values are comma-separated and are attempted in rotating order:

```bash
flutter build linux \
  --dart-define=VPN_CATALOG_SURFSHARK_URLS=https://mirror-a.example/catalog.json,https://mirror-b.example/catalog.json,https://mirror-c.example/catalog.json
```

A failed HTTP request, timeout, malformed catalog, stale revision, checksum failure, or signature failure causes the next mirror to be tried. A remote response is only persisted after Rust validation succeeds.

If no update mirror is configured, `refreshServers()` is a no-op and the application continues with bundled/cache data.

## Endpoint rotation

Each location has a primary hostname and can contain fallback IP addresses. The Rust FFI exposes a rotating endpoint selector that cycles through the primary hostname and fallback addresses. The future platform networking adapters should request the next endpoint after connection failures instead of permanently pinning a location to one endpoint.

## Health and latency ranking

The Rust core keeps provider-independent server health data. A lower score ranks first. The score combines:

- measured latency when supplied by a platform probe;
- a strong penalty for consecutive connection failures;
- a small bonus for previous successful connections.

The FFI exposes health reporting so Linux, Windows, macOS, Android, and iOS adapters can report real probe/connect results. Flutter receives the server list already sorted by the Rust ranking engine.

Do not fabricate latency from UI timing. Real latency measurements should come from an appropriate platform probe once the native adapters are implemented.

## Restricted-network behavior

The intended flow is:

1. launch using bundled/cache data;
2. choose the best currently ranked server;
3. connect without calling the provider API;
4. after connectivity is available, attempt catalog mirrors in rotating order;
5. validate checksum, revision, provider identity, and Ed25519 signature in Rust;
6. atomically cache the update only if it is newer and valid;
7. retain the previous good catalog on every failure;
8. rotate server endpoints and reduce ranking after connection failures.
