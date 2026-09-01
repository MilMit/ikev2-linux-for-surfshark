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
LIVE_FILE = "/run/milmit-surfshark/live.state"
HELPER = "/usr/libexec/milmit-surfshark-helper"
DEVICE_MANAGER = "/usr/lib/milmit-surfshark/hotspot-device-manager.py"
LOCK_FILE = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "milmit-surfshark-indicator.lock")

lock = open(LOCK_FILE, "w")
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(0)

indicator = AppIndicator3.Indicator.new("milmit-surfshark-ikev2", "network-vpn-symbolic", AppIndicator3.IndicatorCategory.SYSTEM_SERVICES)
indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
indicator.set_title("Surfshark IKEv2")

menu = Gtk.Menu()
status_item = Gtk.MenuItem(label="Surfshark IKEv2 · checking…"); status_item.set_sensitive(False); menu.append(status_item)
ip_item = Gtk.MenuItem(label="Public IP: —"); ip_item.set_sensitive(False); menu.append(ip_item)
live_item = Gtk.MenuItem(label="↓ 0 B/s · ↑ 0 B/s · ping —"); live_item.set_sensitive(False); menu.append(live_item)
health_item = Gtk.MenuItem(label="Watchdog: checking…"); health_item.set_sensitive(False); menu.append(health_item)
menu.append(Gtk.SeparatorMenuItem())
connect_item = Gtk.MenuItem(label="Quick Connect"); menu.append(connect_item)
devices_item = Gtk.MenuItem(label="Hotspot devices…"); menu.append(devices_item)
quit_item = Gtk.MenuItem(label="Hide indicator"); menu.append(quit_item)
menu.show_all(); indicator.set_menu(menu)


def read_kv(path):
    state = {}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                if "=" in line:
                    key, value = line.rstrip().split("=", 1)
                    state[key] = value
    except OSError:
        pass
    return state


def rate(value):
    try:
        n = float(value or 0)
    except ValueError:
        n = 0
    if n >= 1024 * 1024:
        return f"{n / (1024 * 1024):.1f} MB/s"
    if n >= 1024:
        return f"{n / 1024:.1f} KB/s"
    return f"{int(n)} B/s"


def refresh():
    state = read_kv(STATE_FILE)
    live = read_kv(LIVE_FILE)
    connected = bool(state.get("VIRTUAL_IP"))
    if connected:
        indicator.set_icon_full("network-vpn-symbolic", "Surfshark IKEv2 connected")
        indicator.set_label("VPN", "VPN")
        status_item.set_label(f"● Surfshark IKEv2 · Connected{(' · ' + state.get('EXIT_COUNTRY')) if state.get('EXIT_COUNTRY') else ''}")
        ip_item.set_label(f"Public IP: {state.get('PUBLIC_IP') or 'connected'}")
        connect_item.set_label("Disconnect VPN")
    else:
        indicator.set_icon_full("network-vpn-disconnected-symbolic", "Surfshark IKEv2 disconnected")
        indicator.set_label("", "VPN")
        status_item.set_label("Surfshark IKEv2 · Disconnected")
        ip_item.set_label("Public IP: —")
        connect_item.set_label("Quick Connect")
    latency = live.get("LATENCY_MS")
    live_item.set_label(f"↓ {rate(live.get('RX_BPS'))} · ↑ {rate(live.get('TX_BPS'))} · ping {(latency + ' ms') if latency and latency != '0' else '—'}")
    health_item.set_label(f"Watchdog: {live.get('HEALTH') or ('STARTING' if connected else 'DISCONNECTED')}")
    devices_item.set_sensitive(bool(state.get("HOTSPOT_IFACE")) and os.path.exists(DEVICE_MANAGER))
    return True


def open_devices(_item):
    if os.path.exists(DEVICE_MANAGER):
        subprocess.Popen(["python3", DEVICE_MANAGER], start_new_session=True)


def toggle_connect(_item):
    if not os.path.exists(HELPER):
        return
    connected = bool(read_kv(STATE_FILE).get("VIRTUAL_IP"))
    subprocess.Popen(["pkexec", HELPER, "disconnect" if connected else "quick-connect"])
    GLib.timeout_add_seconds(1, refresh)


def quit_indicator(_item):
    Gtk.main_quit()


connect_item.connect("activate", toggle_connect)
devices_item.connect("activate", open_devices)
quit_item.connect("activate", quit_indicator)
signal.signal(signal.SIGTERM, lambda *_: Gtk.main_quit())
signal.signal(signal.SIGINT, lambda *_: Gtk.main_quit())
refresh(); GLib.timeout_add_seconds(2, refresh); Gtk.main()
