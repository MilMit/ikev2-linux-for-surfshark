import GLib from 'gi://GLib';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const STATE = '/run/milmit-surfshark/restricted.state';
const LIVE = '/run/milmit-surfshark/live.state';
const DEVICE_MANAGER = '/usr/lib/milmit-surfshark/hotspot-device-manager.py';
const HELPER = '/usr/libexec/milmit-surfshark-helper';

function readKv(path) {
    let text = '';
    try {
        const [ok, bytes] = GLib.file_get_contents(path);
        if (ok)
            text = new TextDecoder().decode(bytes);
    } catch (e) {
        return {};
    }
    const values = {};
    for (const line of text.split('\n')) {
        const idx = line.indexOf('=');
        if (idx > 0)
            values[line.slice(0, idx)] = line.slice(idx + 1);
    }
    return values;
}

function rate(value) {
    const n = Number(value || 0);
    if (n >= 1024 * 1024)
        return `${(n / (1024 * 1024)).toFixed(1)} MB/s`;
    if (n >= 1024)
        return `${(n / 1024).toFixed(1)} KB/s`;
    return `${Math.round(n)} B/s`;
}

export default class SurfsharkIkev2Status extends Extension {
    enable() {
        this._indicator = new PanelMenu.Button(0.0, 'Surfshark IKEv2');
        this._icon = new St.Icon({icon_name: 'network-vpn-disconnected-symbolic', style_class: 'system-status-icon'});
        this._indicator.add_child(this._icon);

        this._statusItem = new PopupMenu.PopupMenuItem('Surfshark IKEv2: disconnected', {reactive: false});
        this._ipItem = new PopupMenu.PopupMenuItem('Public IP: —', {reactive: false});
        this._liveItem = new PopupMenu.PopupMenuItem('↓ 0 B/s · ↑ 0 B/s · ping —', {reactive: false});
        this._healthItem = new PopupMenu.PopupMenuItem('Watchdog: checking…', {reactive: false});
        this._hotspotItem = new PopupMenu.PopupMenuItem('Hotspot sharing: off', {reactive: false});
        this._connectItem = new PopupMenu.PopupMenuItem('Quick Connect');
        this._deviceItem = new PopupMenu.PopupMenuItem('Manage hotspot devices…');

        this._connectItem.connect('activate', () => {
            const connected = Boolean(readKv(STATE).VIRTUAL_IP);
            const cmd = connected ? 'disconnect' : 'quick-connect';
            try {
                GLib.spawn_command_line_async(`pkexec ${HELPER} ${cmd}`);
            } catch (e) {
                logError(e, `Unable to ${cmd} MilMit Surfshark`);
            }
        });
        this._deviceItem.connect('activate', () => {
            try {
                GLib.spawn_command_line_async(`python3 ${DEVICE_MANAGER}`);
            } catch (e) {
                logError(e, 'Unable to open MilMit hotspot device manager');
            }
        });

        this._indicator.menu.addMenuItem(this._statusItem);
        this._indicator.menu.addMenuItem(this._ipItem);
        this._indicator.menu.addMenuItem(this._liveItem);
        this._indicator.menu.addMenuItem(this._healthItem);
        this._indicator.menu.addMenuItem(this._hotspotItem);
        this._indicator.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._indicator.menu.addMenuItem(this._connectItem);
        this._indicator.menu.addMenuItem(this._deviceItem);
        Main.panel.addToStatusArea(this.uuid, this._indicator);

        this._refresh();
        this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 2, () => {
            this._refresh();
            return GLib.SOURCE_CONTINUE;
        });
    }

    _refresh() {
        const values = readKv(STATE);
        const live = readKv(LIVE);
        const connected = Boolean(values.VIRTUAL_IP);
        const health = live.HEALTH || (connected ? 'STARTING' : 'DISCONNECTED');

        this._icon.icon_name = connected ? 'network-vpn-symbolic' : 'network-vpn-disconnected-symbolic';
        this._statusItem.label.text = connected
            ? `Surfshark IKEv2: connected${values.EXIT_COUNTRY ? ' · ' + values.EXIT_COUNTRY : ''}`
            : 'Surfshark IKEv2: disconnected';
        this._ipItem.label.text = `Public IP: ${values.PUBLIC_IP || '—'}`;
        this._liveItem.label.text = `↓ ${rate(live.RX_BPS)} · ↑ ${rate(live.TX_BPS)} · ping ${live.LATENCY_MS && live.LATENCY_MS !== '0' ? live.LATENCY_MS + ' ms' : '—'}`;
        this._healthItem.label.text = `Watchdog: ${health}${live.FAILURES && live.FAILURES !== '0' ? ' · failures ' + live.FAILURES : ''}`;
        const vpnCount = values.HOTSPOT_VPN_MAC_COUNT || '0';
        const directCount = values.HOTSPOT_DIRECT_MAC_COUNT || '0';
        this._hotspotItem.label.text = values.HOTSPOT_IFACE
            ? `Hotspot: ${values.HOTSPOT_IFACE} · VPN ${vpnCount} · Direct ${directCount}`
            : 'Hotspot sharing: off';
        this._connectItem.label.text = connected ? 'Disconnect VPN' : 'Quick Connect';
        this._deviceItem.setSensitive(Boolean(values.HOTSPOT_IFACE));
    }

    disable() {
        if (this._timer) {
            GLib.source_remove(this._timer);
            this._timer = null;
        }
        this._indicator?.destroy();
        this._indicator = null;
    }
}
