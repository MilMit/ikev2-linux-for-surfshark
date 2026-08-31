import GLib from 'gi://GLib';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const STATE = '/run/milmit-surfshark/restricted.state';

export default class SurfsharkIkev2Status extends Extension {
    enable() {
        this._indicator = new PanelMenu.Button(0.0, 'Surfshark IKEv2');
        this._icon = new St.Icon({icon_name: 'network-vpn-symbolic', style_class: 'system-status-icon'});
        this._indicator.add_child(this._icon);
        this._statusItem = new PopupMenu.PopupMenuItem('Surfshark IKEv2: disconnected', {reactive: false});
        this._ipItem = new PopupMenu.PopupMenuItem('Public IP: —', {reactive: false});
        this._hotspotItem = new PopupMenu.PopupMenuItem('Hotspot sharing: off', {reactive: false});
        this._indicator.menu.addMenuItem(this._statusItem);
        this._indicator.menu.addMenuItem(this._ipItem);
        this._indicator.menu.addMenuItem(this._hotspotItem);
        Main.panel.addToStatusArea(this.uuid, this._indicator);
        this._refresh();
        this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 2, () => {
            this._refresh();
            return GLib.SOURCE_CONTINUE;
        });
    }

    _refresh() {
        let text = '';
        try {
            const [ok, bytes] = GLib.file_get_contents(STATE);
            if (ok)
                text = new TextDecoder().decode(bytes);
        } catch (e) {
            text = '';
        }
        const values = {};
        for (const line of text.split('\n')) {
            const idx = line.indexOf('=');
            if (idx > 0)
                values[line.slice(0, idx)] = line.slice(idx + 1);
        }
        const connected = Boolean(values.VIRTUAL_IP);
        this._indicator.visible = connected;
        this._statusItem.label.text = connected
            ? `Surfshark IKEv2: connected${values.EXIT_COUNTRY ? ' · ' + values.EXIT_COUNTRY : ''}`
            : 'Surfshark IKEv2: disconnected';
        this._ipItem.label.text = `Public IP: ${values.PUBLIC_IP || '—'}`;
        this._hotspotItem.label.text = values.HOTSPOT_IFACE
            ? `Hotspot sharing: on · ${values.HOTSPOT_IFACE}`
            : 'Hotspot sharing: off';
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
