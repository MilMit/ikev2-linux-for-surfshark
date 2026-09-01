#!/usr/bin/env python3
import os
import re
import subprocess
from pathlib import Path

try:
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk, GLib
except Exception as exc:
    raise SystemExit(f"GTK3 is required: {exc}")

STATE_FILE = Path("/run/milmit-surfshark/restricted.state")
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "milmit-surfshark"
SETTINGS_FILE = CONFIG_DIR / "settings.conf"
HELPER = "/usr/libexec/milmit-surfshark-helper"
MAC_RE = re.compile(r"^(?:[0-9A-F]{2}:){5}[0-9A-F]{2}$")


def read_kv(path):
    data = {}
    try:
        for raw in Path(path).read_text(encoding="utf-8").splitlines():
            if "=" in raw:
                k, v = raw.split("=", 1)
                data[k] = v
    except OSError:
        pass
    return data


def write_settings(values):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    current = read_kv(SETTINGS_FILE)
    current.update(values)
    order = [
        "restricted", "mss", "dns", "hotspot_vpn", "hotspot_iface",
        "recover_network", "kill_switch", "routing_mode",
        "hotspot_vpn_macs", "hotspot_direct_macs",
    ]
    keys = order + [k for k in current if k not in order]
    SETTINGS_FILE.write_text("".join(f"{k}={current[k]}\n" for k in keys if k in current), encoding="utf-8")


def run(args, timeout=3):
    try:
        return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              text=True, timeout=timeout, check=False).stdout.strip()
    except Exception:
        return ""


def selected_iface(settings, state):
    if state.get("HOTSPOT_IFACE"):
        return state["HOTSPOT_IFACE"]
    requested = settings.get("hotspot_iface", "auto")
    if requested != "auto":
        return requested
    text = run(["nmcli", "-t", "-f", "NAME,DEVICE", "connection", "show", "--active"])
    for line in text.splitlines():
        if ":" not in line:
            continue
        name, dev = line.rsplit(":", 1)
        method = run(["nmcli", "-g", "ipv4.method", "connection", "show", name], timeout=1)
        if method.strip() == "shared":
            return dev
    return ""


def reverse_name(ip):
    out = run(["getent", "hosts", ip], timeout=0.6)
    if not out:
        return ""
    parts = out.split()
    return parts[1] if len(parts) > 1 else ""


def neighbors(iface):
    if not iface:
        return []
    text = run(["ip", "neigh", "show", "dev", iface])
    rows = []
    seen = set()
    for line in text.splitlines():
        parts = line.split()
        if not parts or "lladdr" not in parts:
            continue
        try:
            ip = parts[0]
            mac = parts[parts.index("lladdr") + 1].upper()
        except Exception:
            continue
        if not MAC_RE.match(mac) or mac in seen:
            continue
        state = parts[-1] if parts else ""
        if state in {"FAILED", "INCOMPLETE"}:
            continue
        seen.add(mac)
        rows.append((reverse_name(ip), ip, mac, state))
    return rows


class Manager(Gtk.Window):
    def __init__(self):
        super().__init__(title="Hotspot Device Routing · MilMit")
        self.set_default_size(720, 520)
        self.set_border_width(18)
        self.settings = read_kv(SETTINGS_FILE)
        self.state = read_kv(STATE_FILE)
        self.rows = {}

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.add(root)

        title = Gtk.Label()
        title.set_markup("<span size='x-large' weight='bold'>Hotspot devices</span>")
        title.set_xalign(0)
        root.pack_start(title, False, False, 0)

        self.subtitle = Gtk.Label(label="Detecting devices…")
        self.subtitle.set_xalign(0)
        root.pack_start(self.subtitle, False, False, 0)

        toolbar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.refresh_btn = Gtk.Button(label="Refresh devices")
        self.default_combo = Gtk.ComboBoxText()
        self.default_combo.append("vpn", "Unlisted → VPN")
        self.default_combo.append("direct", "Unlisted → Direct")
        self.default_combo.set_active_id("vpn" if self.settings.get("hotspot_vpn", "1") == "1" else "direct")
        toolbar.pack_start(self.refresh_btn, False, False, 0)
        toolbar.pack_end(self.default_combo, False, False, 0)
        root.pack_start(toolbar, False, False, 0)

        self.listbox = Gtk.ListBox()
        self.listbox.set_selection_mode(Gtk.SelectionMode.NONE)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.add(self.listbox)
        root.pack_start(scroll, True, True, 0)

        self.info = Gtk.Label(label="Default keeps the device on the global hotspot policy. VPN forces Surfshark. Direct bypasses Surfshark.")
        self.info.set_line_wrap(True)
        self.info.set_xalign(0)
        root.pack_start(self.info, False, False, 0)

        actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.apply_btn = Gtk.Button(label="Save & Apply now")
        self.apply_btn.get_style_context().add_class("suggested-action")
        close_btn = Gtk.Button(label="Close")
        actions.pack_end(self.apply_btn, False, False, 0)
        actions.pack_end(close_btn, False, False, 0)
        root.pack_start(actions, False, False, 0)

        self.refresh_btn.connect("clicked", lambda *_: self.refresh())
        self.apply_btn.connect("clicked", lambda *_: self.apply())
        close_btn.connect("clicked", lambda *_: self.destroy())
        self.refresh()

    def policy_for(self, mac):
        vpn = {m for m in self.settings.get("hotspot_vpn_macs", "").upper().split(",") if m}
        direct = {m for m in self.settings.get("hotspot_direct_macs", "").upper().split(",") if m}
        if mac in vpn:
            return "vpn"
        if mac in direct:
            return "direct"
        return "default"

    def refresh(self):
        for child in self.listbox.get_children():
            self.listbox.remove(child)
        self.rows.clear()
        self.settings = read_kv(SETTINGS_FILE)
        self.state = read_kv(STATE_FILE)
        iface = selected_iface(self.settings, self.state)
        devices = neighbors(iface)
        self.subtitle.set_text(f"Interface: {iface or 'not detected'} · {len(devices)} device(s) discovered")
        if not devices:
            row = Gtk.ListBoxRow()
            label = Gtk.Label(label="No neighbors found. Connect devices to the Ubuntu hotspot, then press Refresh devices.")
            label.set_margin_top(18); label.set_margin_bottom(18)
            row.add(label); self.listbox.add(row)
        for name, ip, mac, nstate in devices:
            row = Gtk.ListBoxRow()
            box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
            box.set_border_width(10)
            icon = Gtk.Image.new_from_icon_name("computer-symbolic", Gtk.IconSize.DIALOG)
            box.pack_start(icon, False, False, 0)
            text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            primary = Gtk.Label(label=name or "Connected device"); primary.set_xalign(0)
            primary.get_style_context().add_class("heading")
            secondary = Gtk.Label(label=f"{ip}  ·  {mac}  ·  {nstate}"); secondary.set_xalign(0)
            text.pack_start(primary, False, False, 0); text.pack_start(secondary, False, False, 0)
            box.pack_start(text, True, True, 0)
            combo = Gtk.ComboBoxText()
            combo.append("default", "Default")
            combo.append("vpn", "VPN")
            combo.append("direct", "Direct")
            combo.set_active_id(self.policy_for(mac))
            box.pack_end(combo, False, False, 0)
            row.add(box); self.listbox.add(row)
            self.rows[mac] = combo
        self.listbox.show_all()

    def apply(self):
        vpn, direct = [], []
        for mac, combo in self.rows.items():
            policy = combo.get_active_id() or "default"
            if policy == "vpn":
                vpn.append(mac)
            elif policy == "direct":
                direct.append(mac)
        default_vpn = "1" if self.default_combo.get_active_id() == "vpn" else "0"
        vpn_csv = ",".join(vpn)
        direct_csv = ",".join(direct)
        write_settings({
            "hotspot_vpn": default_vpn,
            "hotspot_vpn_macs": vpn_csv,
            "hotspot_direct_macs": direct_csv,
        })
        if STATE_FILE.exists() and os.path.exists(HELPER):
            proc = subprocess.run(["pkexec", HELPER, "device-policy", default_vpn, vpn_csv, direct_csv],
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
            msg = proc.stdout.strip() or ("Policy applied." if proc.returncode == 0 else "Policy saved; live apply failed.")
        else:
            msg = "Policy saved. It will be used on the next VPN connection."
        dialog = Gtk.MessageDialog(transient_for=self, flags=0, message_type=Gtk.MessageType.INFO,
                                   buttons=Gtk.ButtonsType.OK, text="Hotspot device policy")
        dialog.format_secondary_text(msg)
        dialog.run(); dialog.destroy()
        self.settings = read_kv(SETTINGS_FILE)


if __name__ == "__main__":
    win = Manager()
    win.connect("destroy", Gtk.main_quit)
    win.show_all()
    Gtk.main()
