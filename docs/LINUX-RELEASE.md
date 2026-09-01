# MilMit Secure Linux release packaging

MilMit Secure currently ships Linux-first because the privileged networking backend depends on strongSwan/swanctl, Linux XFRM, iptables/ipset, policy routing, NetworkManager, systemd and Polkit.

## Supported release bundles

### Debian package (.deb) — primary

The Debian package is the complete installation. It contains the Tauri desktop application plus the privileged helper, VPN/router scripts, Polkit policy and systemd services. Its maintainer scripts activate the watchdog/rules services after installation, tear down the VPN datapath before removal, and preserve user configuration on ordinary remove/upgrade. `apt purge` removes credentials, counters and cached MilMit state.

Build locally from the repository root:

```bash
bash scripts/build-linux-release.sh
```

or from `apps/desktop`:

```bash
npm run bundle:linux
```

### AppImage — portable UI companion

The AppImage is useful as a portable desktop UI, but it is not a standalone privileged VPN installer. The Linux backend must already be installed (normally by installing the `.deb` once). This is intentional: systemd, Polkit and root-owned routing helpers cannot safely live only in a transient AppImage mount.

## Icons

`apps/desktop/src-tauri/icons/icon.svg` is the single source of truth. `scripts/prepare-tauri-icons.sh` renders the 32, 128, 256 and 512 px PNGs used by Tauri, so local builds and CI use exactly the same branding.

## GitHub Actions

`.github/workflows/linux-release.yml` builds on Ubuntu 22.04 for a conservative Linux glibc baseline. It runs manually with **workflow_dispatch** and automatically for tags matching `v*`. Tagged runs upload the `.deb`, `.AppImage` and `SHA256SUMS.txt` to the GitHub Release.

Example release:

```bash
git tag v0.1.0
git push origin v0.1.0
```

## Uninstall semantics

- `sudo apt remove milmit-secure-desktop`: removes application/backend files while preserving user credentials and persistent state for a future reinstall.
- `sudo apt purge milmit-secure-desktop`: also deletes `/etc/milmit-surfshark`, `/var/lib/milmit-surfshark`, runtime state and MilMit logs.

Before package removal, MilMit performs a best-effort emergency network teardown so stale VPN/firewall routes do not leave the machine offline.
