MilMit Secure AppImage
======================

This AppImage contains the desktop UI. MilMit Secure's VPN/router backend uses
Linux system services, Polkit, strongSwan, XFRM and firewall/routing rules that
must live outside the AppImage sandbox/mount.

Recommended setup:
1. Install the MilMit Secure .deb package once on Ubuntu/Debian-family systems.
2. The .deb installs and activates the privileged backend.
3. You may then run the AppImage as an alternate/portable UI against that
   installed backend.

If /usr/libexec/milmit-surfshark-helper is missing, install the .deb package
instead of trying to run the AppImage as a standalone VPN installation.
