#!/usr/bin/env python3
import fcntl
import os
import signal
import subprocess
import sys

try:
    import gi
    gi.require_version("Gtk", "3.0")
    try:
        gi.require_version("AyatanaAppIndicator3", "0.1")
        from gi.repository import AyatanaAppIndicator3 as AppIndicator3
    except (ValueError, ImportError):
        gi.require_version("AppIndicator3", "0.1")
        from gi.repository import AppIndicator3
    from gi.repository import GLib, Gtk
except Exception as exc:
    print(f"Surfshark tray indicator unavailable: {exc}", file=sys.stderr)
    sys.exit(0)

STATE_FILE = "/run/milmit-surfshark/restricted.state"
HELPER = "/usr/libexec/milmit-surfshark-helper"
DEVICE_MANAGER = "/usr/lib/milmit-surfshark/hotspot-device-manager.py"
LOCK_FILE = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "milmit-surfshark-indicator.lock")

lock = open(LOCK_FILE, "w")
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(0)

indicator = AppIndicator3.Indicator.new(
    "milmit-surfshark-ikev2",
    "network-vpn-symbolic",
    AppIndicator3.IndicatorCategory.SYSTEM_SERVICES,
)
indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
indicator.set_title("Surfshark IKEv2")

menu = Gtk.Menu()
status_item = Gtk.MenuItem(label="Surfshark IKEv2 · checking…")
status_item.set_sensitive(False)
menu.append(status_item)

ip_item = Gtk.MenuItem(label="Public IP: —")
ip_item.set_sensitive(False)
menu.append(ip_item)

menu.append(Gtk.SeparatorMenuItem())

devices_item = Gtk.MenuItem(label="Hotspot devices…")
menu.append(devices_item)

disconnect_item = Gtk.MenuItem(label="Disconnect VPN")
menu.append(disconnect_item)

quit_item = Gtk.MenuItem(label="Hide indicator")
menu.append(quit_item)

menu.show_all()
indicator.set_menu(menu)


def read_state():
    state = {}
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as handle:
            for line in handle:
                if "=" in line:
                    key, value = line.rstrip().split("=", 1)
                    state[key] = value
    except OSError:
        pass
    return state


def public_ip(vip):
    if not vip:
        return ""
    try:
        proc = subprocess.run(
            ["curl", "-4", "--interface", vip, "--max-time", "3", "-sS", "https://api.ipify.org"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
            check=False,
        )
        return proc.stdout.strip() if proc.returncode == 0 else ""
    except Exception:
        return ""


def refresh():
    state = read_state()
    connected = bool(state.get("VIRTUAL_IP"))
    if connected:
        indicator.set_icon_full("network-vpn-symbolic", "Surfshark IKEv2 connected")
        indicator.set_label("VPN", "VPN")
        status_item.set_label("● Surfshark IKEv2 · Connected")
        disconnect_item.set_sensitive(True)
        ip = public_ip(state.get("VIRTUAL_IP"))
        ip_item.set_label(f"Public IP: {ip or 'connected'}")
    else:
        indicator.set_icon_full("network-vpn-disconnected-symbolic", "Surfshark IKEv2 disconnected")
        indicator.set_label("", "VPN")
        status_item.set_label("Surfshark IKEv2 · Disconnected")
        ip_item.set_label("Public IP: —")
        disconnect_item.set_sensitive(False)
    devices_item.set_sensitive(os.path.exists(DEVICE_MANAGER))
    return True


def open_devices(_item):
    if os.path.exists(DEVICE_MANAGER):
        subprocess.Popen(["python3", DEVICE_MANAGER], start_new_session=True)


def disconnect(_item):
    if os.path.exists(HELPER):
        subprocess.Popen(["pkexec", HELPER, "disconnect"])
    GLib.timeout_add_seconds(1, refresh)


def quit_indicator(_item):
    Gtk.main_quit()


devices_item.connect("activate", open_devices)
disconnect_item.connect("activate", disconnect)
quit_item.connect("activate", quit_indicator)

signal.signal(signal.SIGTERM, lambda *_: Gtk.main_quit())
signal.signal(signal.SIGINT, lambda *_: Gtk.main_quit())

refresh()
GLib.timeout_add_seconds(3, refresh)
Gtk.main()
