# Debian maintainer scripts

These scripts are consumed by Tauri's Debian bundler. They are not interactive installers.

- `postinstall.sh` activates the root-owned backend services after dpkg has unpacked all files.
- `preremove.sh` tears down MilMit routing before package removal so stale firewall/policy routes cannot strand the host offline.
- `postremove.sh` reloads system services and removes persistent credentials/state only on `apt purge`.
