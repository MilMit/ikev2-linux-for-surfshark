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

The Rust core validates schema version, provider identity, required location fields, supported IKE ports, revision monotonicity, and SHA-256 integrity before accepting a remote catalog.

SHA-256 detects corruption or accidental modification. It is **not** an authenticity guarantee. Remote catalog signing with a project-controlled public key remains a separate production-hardening requirement before untrusted update infrastructure is used.

## Remote transport

Flutter's Rust FFI adapter can retrieve a remote catalog over HTTP(S) and passes the bytes to Rust for validation and atomic cache persistence. No remote URL is hard-coded in the UI.

For Surfshark builds the source can be supplied at build time:

```bash
flutter build linux \
  --dart-define=VPN_CATALOG_SURFSHARK_URL=https://example.invalid/catalogs/surfshark.json
```

Do not ship the placeholder URL above. Use a controlled endpoint or mirror only after server metadata redistribution and update-signing policy are settled.

If no update URL is configured, `refreshServers()` is a no-op and the app continues using its validated bundled/cache data.

## Restricted-network behavior

The intended flow is:

1. launch using bundled/cache data;
2. connect without calling the provider API;
3. after connectivity is available, attempt a catalog refresh;
4. validate the downloaded catalog in Rust;
5. atomically cache it only if it is newer and valid;
6. retain the previous good catalog on any error.
