# IKEv2 Linux for Surfshark

An **unofficial** Linux IKEv2 client focused on simple Surfshark manual connections.

> This project is not affiliated with, endorsed by, or sponsored by Surfshark.
> Surfshark is a trademark of its respective owner. This project does not ship Surfshark account credentials.

## Goals

- IKEv2 only
- Ubuntu-first
- Offline-capable provider/location database
- One-time entry of Surfshark **service credentials**
- Country/city selection
- StrongSwan backend
- Secure secret storage
- Future GTK4/libadwaita UI
- Iran-friendly endpoint fallback design
- No scraping of Surfshark login pages

## Status

Early development scaffold — **v0.1.0-dev**.

## Security model

The application should never store the Surfshark service password in plaintext configuration files.
The GUI should run unprivileged. Privileged VPN actions will be isolated behind a narrow helper/polkit boundary.

## Repository layout

```text
.
├── crates/
│   ├── core/           # provider model, validation, connection planning
│   └── cli/            # first test client
├── providers/
│   └── surfshark/
│       ├── locations.example.json
│       └── README.md
├── docs/
│   ├── ARCHITECTURE.md
│   └── ROADMAP.md
└── .github/workflows/
```

## Build

```bash
cargo build
cargo test
```

## First development target

The first milestone is deliberately small:

1. Read Surfshark service credentials from the user.
2. Read a bundled Surfshark location entry.
3. Validate hostname/IP/certificate metadata.
4. Produce an IKEv2 connection plan.
5. Later hand that plan to the privileged StrongSwan integration.

We are **not** implementing Surfshark email/password login or 2FA scraping.

## License

MIT for project code. Third-party certificates/server metadata must be reviewed separately before redistribution.
