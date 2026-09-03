<div align="center">

# 🛡️ MilMit Secure

**Next-Generation Unofficial IKEv2 Linux Client for Surfshark & StrongSwan**

[![Rust](https://img.shields.io/badge/Rust-1.80+-orange.svg?style=for-the-badge&logo=rust)](https://www.rust-lang.org/)
[![Tauri](https://img.shields.io/badge/Tauri-v2-blue.svg?style=for-the-badge&logo=tauri)](https://tauri.app/)
[![React](https://img.shields.io/badge/React-18-61DAFB.svg?style=for-the-badge&logo=react)](https://react.dev/)
[![TypeScript](https://img.shields.io/badge/TypeScript-5.6-3178C6.svg?style=for-the-badge&logo=typescript)](https://www.typescriptlang.org/)
[![Platform](https://img.shields.io/badge/Platform-Ubuntu%20%7C%20Debian%20%7C%20Linux-E95420.svg?style=for-the-badge&logo=ubuntu)](https://ubuntu.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg?style=for-the-badge)](LICENSE)

*A privacy-first, ultra-responsive desktop VPN client crafted for Linux users, featuring zero-plaintext credential storage, real-time traffic waveforms, isolated namespace split tunneling, and hotspot protection.*

Created by [Milad Dadgar](https://github.com/miladdadgar) &bull; Published under [MilMit](https://github.com/MilMit)

</div>

---

## ✨ Features & Highlights

### 🔮 Modern Cyber-Glassmorphic UI & Animations
- **Multi-State Animated Status Orb:** Dynamic visual states for *Disconnected* (breathing glow), *Connecting/Authenticating* (concentric radar sweep & orbital rings), *Connected* (emerald liquid pulse), and *Cancelling*.
- **Live Real-time Traffic Waveform:** 60 FPS SVG sparkline graph rendering upload/download bandwidth streams and daily/monthly data counters.
- **Interactive Route Visualizer:** Visual connection beam mapping your local device to the destination server with latency markers.
- **Smart Server Selector:** Instant probing and auto-sorting of locations with colored ping indicators (`< 100ms` green, `< 200ms` amber, `> 200ms` red).

### 🔒 Enterprise-Grade Security Model
- **Zero Plaintext Credentials:** Surfshark service credentials are saved via a narrow root-isolated helper into `/etc/milmit-surfshark/credentials` (0600 root-only) and never stored in application config files or passed via command line arguments.
- **Kill Switch & Lockdown Mode:** Automatic firewall isolation preventing leaks when the VPN disconnects.
- **DNS Leak Protection:** Automatically enforces secure local resolvers and validates routes.

### 🌐 Advanced Linux Networking
- **Namespace-Isolated Split Tunneling:** Applications run in isolated Linux network namespaces (`ip netns`) to bypass the VPN without touching global routing rules.
- **Custom Domain & IP Policies:** Easy toggle for `Force VPN`, `Direct Bypass`, or `Block` per domain/CIDR.
- **Iran CIDR Domestic Route Rules:** Fast fallback rules allowing domestic traffic to stay direct while tunneling restricted destinations.
- **Protected Wi-Fi Hotspot & Device Manager:** Share the VPN over a local hotspot with per-device rate limiting, bandwidth quotas, client isolation, and temporary guest SSIDs.

### 💻 Integrated Live Terminal HUD
- **Live Event Streaming:** Real-time log console with auto-redaction of sensitive keys/passwords, search filtering, level highlighting (Info, Warning, Error, Success), and one-click copy.
- **Built-in Network Doctor:** One-click diagnostics for MTU/MSS probing, StrongSwan tunnel health, DNS resolution, and sanitized support bundle generation.

---

## 🚀 Quick Start & Development

### Prerequisites

Make sure you have the required dependencies on Ubuntu / Debian:

```bash
sudo apt update
sudo apt install -y build-essential libssl-dev libgtk-3-dev libwebkit2gtk-4.1-dev \
                    libayatana-appindicator3-dev librsvg2-dev strongswan libcharon-extra-plugins
```

### 1. Clone the repository

```bash
git clone https://github.com/MilMit/MilMit-Secure.git
cd MilMit-Secure
```

### 2. Install Desktop UI dependencies

```bash
cd apps/desktop
npm install
```

### 3. Run in Development Mode

```bash
# In apps/desktop
npm run tauri dev
```

### 4. Build Production Packages (.deb & .AppImage)

```bash
# Build desktop web assets & Tauri application
npm run build
npm run bundle:linux
```

The generated `.deb` and `.AppImage` packages will be placed in `packaging/dist/`.

---

## 📁 Repository Layout

```text
.
├── apps/
│   └── desktop/            # Tauri v2 + React 18 + TypeScript GUI Application
│       ├── src/
│       │   ├── components/ # TrafficChart, RouteBeam, CredentialsModal, LogTerminal
│       │   ├── main.tsx    # Unified React shell & dashboard
│       │   └── styles.css  # Cyber-Glassmorphic dark design system
│       └── src-tauri/      # Tauri Rust backend, IPC handlers & system services
├── crates/
│   ├── core/               # Provider model, config parsing, connection planning
│   ├── cli/                # Command-line interface client
│   └── gui/                # Native GTK helper utilities
├── providers/
│   └── surfshark/          # Bundled server locations database & CA certificates
├── docs/                   # Architecture specs, security whitepaper & roadmaps
├── packaging/              # Debian & AppImage packaging scripts
└── .github/workflows/      # Automated CI/CD build & release pipelines
```

---

## 🛡️ Security & Privacy Notice

- **No Credential Scraping:** MilMit Secure never asks for your personal Surfshark account password or email. You only provide manual setup **Service Credentials**.
- **Privilege Separation:** The graphical interface runs as an unprivileged user. Privileged VPN networking changes are isolated behind narrow polkit/helper actions.
- **Disclaimer:** This project is an unofficial open-source tool and is not affiliated with, endorsed by, or sponsored by Surfshark.

---

## 📜 License

Distributed under the **MIT License**. See [LICENSE](LICENSE) for details.
