# Architecture

## Principle

The desktop UI must not run as root.

```text
GTK/libadwaita UI
       |
       v
unprivileged Rust application
       |
       +---- Secret Service / GNOME Keyring
       |
       +---- provider database (bundled + signed updates)
       |
       v
narrow privileged helper
       |
       v
StrongSwan / VICI / swanctl
       |
       v
IKEv2 tunnel
```

## Provider database

The bundled database exists so the application can start and select locations
without downloading configuration from Surfshark first.

Each entry should support:

- stable local id
- country/city
- canonical hostname
- one or more fallback IPs
- certificate identifier
- health metadata
- database version

Do not rely on fallback IPs forever: server IPs can change.

## Iran-oriented resilience

Design requirements:

1. bundled provider database;
2. hostname first, known-IP fallback second;
3. optional alternate resolver path;
4. multiple endpoints per location;
5. endpoint health checks;
6. signed database updates;
7. app remains functional if updates fail.

## Authentication

Use Surfshark **service credentials** for manual IKEv2.

Do not implement web-login scraping or 2FA automation unless a stable,
documented and permitted API becomes available.

## Privilege boundary

Never put a general-purpose `sudo` shell in the GUI.

The privileged component must expose only narrowly defined operations such as:

- install/update a generated StrongSwan connection
- connect a known profile
- disconnect
- query tunnel status
- apply/remove kill-switch rules

Every input must be validated before crossing the privilege boundary.
