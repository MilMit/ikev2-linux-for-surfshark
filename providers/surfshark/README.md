# Surfshark provider data

This directory contains the Surfshark provider schema and bundled server catalog used by the client.

`locations.example.json` and the current `provider.json` intentionally contain **placeholder endpoints**. Do not treat them as a working Surfshark server list.

`provider.json` now uses the versioned catalog envelope consumed by the Rust catalog engine. The runtime can prefer a newer validated cache over the bundled revision and fall back to the bundled catalog when refresh fails.

Before shipping real data, verify:

- redistribution rights for server metadata;
- certificate redistribution terms;
- current Surfshark IKEv2/WireGuard/OpenVPN endpoint values;
- production catalog signing with a project-controlled public key;
- trusted update/mirror infrastructure.

SHA-256 in the current envelope is an integrity check, not a substitute for a digital signature.

Secrets must never be committed here.
