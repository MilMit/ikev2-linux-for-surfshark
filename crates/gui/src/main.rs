mod bundled_endpoints;
mod locations;

use adw::prelude::*;
use bundled_endpoints::for_host as bundled_for_host;
use gtk::{glib, Orientation};
use locations::{by_id, LOCATIONS};
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::rc::Rc;
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

const PROFILE: &str = "MilMit Surfshark IKEv2";
const CA_CERT: &str = "/etc/swanctl/x509ca/surfshark_ikev2.crt";
const RESTRICTED_CONNECT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../scripts/restricted-ikev2-connect.sh");
const RESTRICTED_DISCONNECT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../scripts/restricted-ikev2-disconnect.sh");
const RESTRICTED_STATE: &str = "/run/milmit-surfshark/restricted.state";
const DEFAULT_DNS: &str = "162.252.172.57,149.154.159.92";

#[derive(Clone)]
struct AppSettings {
    restricted: bool,
    mss: u32,
    dns: String,
    hotspot_vpn: bool,
    hotspot_iface: String,
    recover_network: bool,
    kill_switch: bool,
    routing_mode: String,
    hotspot_vpn_macs: String,
    hotspot_direct_macs: String,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            restricted: true,
            mss: 1200,
            dns: DEFAULT_DNS.to_string(),
            hotspot_vpn: true,
            hotspot_iface: "auto".to_string(),
            recover_network: true,
            kill_switch: true,
            routing_mode: "vpn_all".to_string(),
            hotspot_vpn_macs: String::new(),
            hotspot_direct_macs: String::new(),
        }
    }
}

#[derive(Debug)]
enum Event {
    Busy(String),
    Log(String, String),
    Connected(String, String, String),
    Disconnected,
    Failed(String),
    Refreshed(bool, String),
    PingStarted,
    PingResults(Vec<(String, Option<u32>)>),
}

fn run(cmd: &str, args: &[&str]) -> String {
    match Command::new(cmd).args(args).output() {
        Ok(out) => {
            let mut text = String::new();
            if !out.stdout.is_empty() { text.push_str(&String::from_utf8_lossy(&out.stdout)); }
            if !out.stderr.is_empty() {
                if !text.is_empty() { text.push('\n'); }
                text.push_str(&String::from_utf8_lossy(&out.stderr));
            }
            if text.trim().is_empty() { format!("exit: {}", out.status) } else { text }
        }
        Err(e) => format!("Failed to run {cmd}: {e}"),
    }
}

fn nm(args: &[&str]) -> String { run("nmcli", args) }

fn nm_active() -> bool {
    nm(&["-t", "-f", "NAME,TYPE", "connection", "show", "--active"])
        .lines().any(|line| line == format!("{PROFILE}:vpn"))
}

fn profile_exists() -> bool {
    nm(&["-t", "-f", "NAME", "connection", "show"])
        .lines().any(|line| line == PROFILE)
}

fn state_value(key: &str) -> Option<String> {
    let state = fs::read_to_string(RESTRICTED_STATE).ok()?;
    state.lines().find_map(|line| {
        let (k, v) = line.split_once('=')?;
        (k == key).then(|| v.trim().to_string())
    }).filter(|v| !v.is_empty())
}

fn restricted_active() -> bool {
    let Some(vip) = state_value("VIRTUAL_IP") else { return false; };
    run("ip", &["-4", "addr", "show"]).contains(&vip)
}

fn any_vpn_active() -> bool { restricted_active() || nm_active() }

fn config_dir() -> PathBuf {
    std::env::var("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|_| std::env::var("HOME").map(|h| PathBuf::from(h).join(".config")))
        .unwrap_or_else(|_| PathBuf::from("."))
        .join("milmit-surfshark")
}

fn username_path() -> PathBuf { config_dir().join("username") }
fn settings_path() -> PathBuf { config_dir().join("settings.conf") }

fn saved_username() -> Option<String> {
    fs::read_to_string(username_path()).ok().map(|v| v.trim().to_string()).filter(|v| !v.is_empty())
}

fn save_username(value: &str) {
    let path = username_path();
    if let Some(parent) = path.parent() { let _ = fs::create_dir_all(parent); }
    let _ = fs::write(path, value);
}

fn normalize_mac_csv(value: &str) -> String {
    let mut out: Vec<String> = Vec::new();
    for item in value.split(',') {
        let mac = item.trim().to_ascii_uppercase();
        if mac.is_empty() { continue; }
        if !out.iter().any(|v| v == &mac) { out.push(mac); }
    }
    out.join(",")
}

fn load_settings() -> AppSettings {
    let mut settings = AppSettings::default();
    let Ok(text) = fs::read_to_string(settings_path()) else { return settings; };
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else { continue; };
        match key {
            "restricted" => settings.restricted = value == "1",
            "mss" => if let Ok(v) = value.parse::<u32>() { if (900..=1400).contains(&v) { settings.mss = v; } },
            "dns" => if !value.trim().is_empty() { settings.dns = value.trim().to_string(); },
            "hotspot_vpn" => settings.hotspot_vpn = value == "1",
            "hotspot_iface" => if !value.trim().is_empty() { settings.hotspot_iface = value.trim().to_string(); },
            "recover_network" => settings.recover_network = value == "1",
            "kill_switch" => settings.kill_switch = value == "1",
            "routing_mode" => if matches!(value, "vpn_all" | "iran_direct") { settings.routing_mode = value.to_string(); },
            "hotspot_vpn_macs" => settings.hotspot_vpn_macs = normalize_mac_csv(value),
            "hotspot_direct_macs" => settings.hotspot_direct_macs = normalize_mac_csv(value),
            _ => {}
        }
    }
    settings
}

fn save_settings(settings: &AppSettings) {
    let path = settings_path();
    if let Some(parent) = path.parent() { let _ = fs::create_dir_all(parent); }
    let text = format!(
        "restricted={}\nmss={}\ndns={}\nhotspot_vpn={}\nhotspot_iface={}\nrecover_network={}\nkill_switch={}\nrouting_mode={}\nhotspot_vpn_macs={}\nhotspot_direct_macs={}\n",
        settings.restricted as u8,
        settings.mss,
        settings.dns,
        settings.hotspot_vpn as u8,
        settings.hotspot_iface,
        settings.recover_network as u8,
        settings.kill_switch as u8,
        settings.routing_mode,
        settings.hotspot_vpn_macs,
        settings.hotspot_direct_macs,
    );
    let _ = fs::write(path, text);
}

fn public_ip() -> String { run("curl", &["-4", "--max-time", "8", "-sS", "https://api.ipify.org"]) }

fn network_interfaces() -> Vec<(String, String)> {
    let mut out = Vec::new();
    let text = nm(&["-t", "-f", "DEVICE,TYPE,STATE", "device", "status"]);
    for line in text.lines() {
        let mut parts = line.splitn(3, ':');
        let dev = parts.next().unwrap_or("").trim();
        let kind = parts.next().unwrap_or("").trim();
        let state = parts.next().unwrap_or("").trim();
        if dev.is_empty() || dev == "lo" || matches!(kind, "loopback" | "dummy" | "tun") { continue; }
        if !matches!(kind, "wifi" | "ethernet" | "bridge") { continue; }
        let icon = if kind == "wifi" { "📶" } else { "🔌" };
        out.push((dev.to_string(), format!("{icon} {dev} · {kind} · {state}")));
    }
    out
}

fn configure_nm_profile(address: &str, identity: &str, username: &str, password: Option<&str>) -> String {
    let mut log = String::new();
    if !profile_exists() {
        log.push_str(&nm(&["connection", "add", "type", "vpn", "ifname", "--", "vpn-type", "strongswan", "connection.id", PROFILE, "connection.autoconnect", "no"]));
        log.push('\n');
    }
    let data = format!("address = {address}, server-identity = {identity}, certificate = {CA_CERT}, encap = yes, ipcomp = no, method = eap, proposal = no, user = {username}, virtual = yes");
    let mut cmd = Command::new("nmcli");
    cmd.args(["connection", "modify", PROFILE, "vpn.data", &data, "ipv4.never-default", "no", "ipv6.method", "disabled"]);
    if let Some(password) = password { cmd.args(["vpn.secrets", &format!("password={password}")]); }
    match cmd.output() {
        Ok(out) => {
            log.push_str(&String::from_utf8_lossy(&out.stdout));
            log.push_str(&String::from_utf8_lossy(&out.stderr));
        }
        Err(e) => log.push_str(&format!("nmcli failed: {e}")),
    }
    log
}

fn standard_connect(host: &str, username: &str, password: Option<&str>) -> (bool, String) {
    if nm_active() { let _ = nm(&["--wait", "5", "connection", "down", PROFILE]); }
    let mut log = configure_nm_profile(host, host, username, password);
    log.push('\n');
    log.push_str(&nm(&["--wait", "15", "connection", "up", PROFILE]));
    (nm_active(), log)
}

fn restricted_candidates(host: &str) -> Vec<String> {
    let mut out = Vec::new();
    if host == "ee-tll.prod.surfshark.com" { out.push("185.174.159.123".to_string()); }
    for ip in bundled_for_host(host) {
        if !out.iter().any(|v| v == ip) { out.push((*ip).to_string()); }
    }
    out
}

fn restricted_connect(endpoint: &str, username: &str, password: &str, settings: &AppSettings) -> (bool, String) {
    let mss = settings.mss.to_string();
    let hotspot = if settings.hotspot_vpn { "1" } else { "0" };
    let recover = if settings.recover_network { "1" } else { "0" };
    let kill = if settings.kill_switch { "1" } else { "0" };
    let mut child = match Command::new("pkexec")
        .arg("bash")
        .arg(RESTRICTED_CONNECT)
        .arg(endpoint)
        .arg(username)
        .arg(&mss)
        .arg(&settings.dns)
        .arg(hotspot)
        .arg(recover)
        .arg(&settings.hotspot_iface)
        .arg(kill)
        .arg(&settings.routing_mode)
        .arg(&settings.hotspot_vpn_macs)
        .arg(&settings.hotspot_direct_macs)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(e) => return (false, format!("Could not start restricted helper: {e}")),
    };
    if let Some(stdin) = child.stdin.as_mut() { let _ = writeln!(stdin, "{password}"); }
    match child.wait_with_output() {
        Ok(out) => {
            let mut text = String::from_utf8_lossy(&out.stdout).to_string();
            if !out.stderr.is_empty() {
                if !text.is_empty() { text.push('\n'); }
                text.push_str(&String::from_utf8_lossy(&out.stderr));
            }
            (out.status.success() && text.contains("Data-path test: OK"), text)
        }
        Err(e) => (false, format!("Restricted helper failed: {e}")),
    }
}

fn restricted_disconnect() -> String { run("pkexec", &["bash", RESTRICTED_DISCONNECT]) }

fn parse_helper_value(text: &str, key: &str) -> Option<String> {
    text.lines().find_map(|line| {
        let (k, v) = line.split_once(':')?;
        (k.trim() == key).then(|| v.trim().to_string())
    }).filter(|v| !v.is_empty())
}

fn ping_ms(host: &str) -> Option<u32> {
    let target = if host == "ee-tll.prod.surfshark.com" { "185.174.159.123" } else { bundled_for_host(host).first().copied().unwrap_or(host) };
    let output = Command::new("ping").args(["-n", "-c", "1", "-W", "1", target]).output().ok()?;
    if !output.status.success() { return None; }
    let text = String::from_utf8_lossy(&output.stdout);
    let start = text.find("time=")? + 5;
    let rest = &text[start..];
    let end = rest.find(|c: char| c == ' ' || c == '\n').unwrap_or(rest.len());
    rest[..end].parse::<f64>().ok().map(|v| v.round() as u32)
}

fn scan_latencies() -> Vec<(String, Option<u32>)> {
    LOCATIONS.iter().map(|item| (item.id.to_string(), ping_ms(item.host))).collect()
}

fn repopulate_locations(combo: &gtk::ComboBoxText, results: &[(String, Option<u32>)]) {
    let active = combo.active_id().map(|s| s.to_string());
    combo.remove_all();
    for item in LOCATIONS {
        let latency = results.iter().find(|(id, _)| id == item.id).and_then(|(_, value)| *value);
        let label = match latency {
            Some(ms) if ms < 100 => format!("🟢 {} · {} ms", item.label, ms),
            Some(ms) if ms < 220 => format!("🟡 {} · {} ms", item.label, ms),
            Some(ms) => format!("🟠 {} · {} ms", item.label, ms),
            None => format!("⚪ {} · no ping", item.label),
        };
        combo.append(Some(item.id), &label);
    }
    if let Some(id) = active { combo.set_active_id(Some(&id)); } else { combo.set_active(Some(0)); }
}

fn append_log(buffer: &gtk::TextBuffer, title: &str, body: &str) {
    let mut end = buffer.end_iter();
    buffer.insert(&mut end, &format!("\n=== {title} ===\n{body}\n"));
}

fn install_css() {
    let provider = gtk::CssProvider::new();
    provider.load_from_data(
        ".hero { padding: 28px; border-radius: 24px; background: linear-gradient(135deg, alpha(@accent_bg_color,.20), rgba(35,190,155,.11)); }\n\
         .hero-title { font-size: 29px; font-weight: 800; }\n\
         .hero-subtitle { font-size: 13px; }\n\
         .status-pill { padding: 8px 13px; border-radius: 999px; background: alpha(@accent_bg_color, .14); font-weight: 700; }\n\
         .vpn-orb { padding: 13px; border-radius: 999px; background: alpha(@accent_bg_color,.12); }\n\
         .panel { padding: 15px; border-radius: 16px; background: alpha(@card_bg_color,.45); }\n\
         .settings-box { padding: 14px; border-radius: 16px; background: alpha(@view_bg_color,.35); }\n\
         .primary-connect { min-height: 48px; padding-left: 38px; padding-right: 38px; font-weight: 700; }\n\
         .small-note { font-size: 11px; }\n\
         .diag-box { font-size: 12px; }\n\
         .connection-progress { min-height: 5px; }"
    );
    if let Some(display) = gtk::gdk::Display::default() {
        gtk::style_context_add_provider_for_display(&display, &provider, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
    }
}

fn main() -> glib::ExitCode {
    let app = adw::Application::builder().application_id("net.milmit.SurfsharkIkev2").build();
    app.connect_activate(build_ui);
    app.run()
}

fn build_ui(app: &adw::Application) {
    install_css();
    let settings = load_settings();
    let initially_active = any_vpn_active();

    let header = adw::HeaderBar::new();
    header.set_title_widget(Some(&adw::WindowTitle::new("Surfshark IKEv2", "Unofficial Linux client by MilMit")));

    let status_icon = gtk::Image::from_icon_name(if initially_active { "network-vpn-symbolic" } else { "network-offline-symbolic" });
    status_icon.set_pixel_size(28); status_icon.add_css_class("vpn-orb");
    let status = gtk::Label::builder().label(if initially_active { "Connected" } else { "Ready to connect" }).css_classes(["status-pill"]).build();
    let hero_detail = gtk::Label::builder().label(if initially_active { "Encrypted tunnel is active" } else { "Choose a location and connect securely" }).halign(gtk::Align::Start).css_classes(["dim-label", "hero-subtitle"]).build();
    let spinner = gtk::Spinner::new();
    let progress = gtk::ProgressBar::new(); progress.add_css_class("connection-progress"); progress.set_visible(false); progress.set_pulse_step(0.09);

    let hero_top = gtk::Box::new(Orientation::Horizontal, 12);
    hero_top.append(&status_icon); hero_top.append(&status); hero_top.append(&spinner);
    let hero = gtk::Box::new(Orientation::Vertical, 11); hero.add_css_class("hero");
    hero.append(&hero_top);
    hero.append(&gtk::Label::builder().label("Private. Fast. Native IKEv2.").halign(gtk::Align::Start).css_classes(["hero-title"]).build());
    hero.append(&hero_detail); hero.append(&progress);

    let location = gtk::ComboBoxText::new(); location.set_hexpand(true);
    for item in LOCATIONS { location.append(Some(item.id), item.label); }
    location.set_active_id(Some("ee-tll"));
    let ping_button = gtk::Button::with_label("Test latency");
    let location_row = gtk::Box::new(Orientation::Horizontal, 8); location_row.append(&location); location_row.append(&ping_button);
    let location_box = gtk::Box::new(Orientation::Vertical, 7); location_box.add_css_class("panel");
    location_box.append(&gtk::Label::builder().label("Location").halign(gtk::Align::Start).css_classes(["heading"]).build());
    location_box.append(&location_row);
    location_box.append(&gtk::Label::builder().label("🟢 fast · 🟡 medium · 🟠 slow · ⚪ no ICMP reply").halign(gtk::Align::Start).css_classes(["dim-label", "small-note"]).build());

    let restricted_mode = gtk::CheckButton::with_label("Restricted network / Iran compatibility mode"); restricted_mode.set_active(settings.restricted);
    let user = gtk::Entry::builder().placeholder_text("Surfshark service username").hexpand(true).build();
    if let Some(name) = saved_username() { user.set_text(&name); }
    let pass = gtk::PasswordEntry::builder().placeholder_text("Service password · blank = use saved password").show_peek_icon(true).hexpand(true).build();
    let mss = gtk::SpinButton::with_range(900.0, 1400.0, 10.0); mss.set_value(settings.mss as f64); mss.set_tooltip_text(Some("1200 is the verified safe value for filtered/mobile Iranian networks."));
    let dns = gtk::Entry::builder().text(&settings.dns).placeholder_text(DEFAULT_DNS).hexpand(true).build();

    let routing_mode = gtk::ComboBoxText::new(); routing_mode.set_hexpand(true);
    routing_mode.append(Some("vpn_all"), "🌐 VPN Everything");
    routing_mode.append(Some("iran_direct"), "🇮🇷 Iran Direct · Foreign through VPN");
    routing_mode.set_active_id(Some(&settings.routing_mode));
    let kill_switch = gtk::CheckButton::with_label("Kill Switch · block public traffic if VPN path fails"); kill_switch.set_active(settings.kill_switch);

    let hotspot_vpn = gtk::CheckButton::with_label("Unlisted hotspot devices use VPN policy"); hotspot_vpn.set_active(settings.hotspot_vpn);
    let hotspot_iface = gtk::ComboBoxText::new(); hotspot_iface.set_hexpand(true);
    hotspot_iface.append(Some("auto"), "⚡ Auto-detect active hotspot");
    for (iface, label) in network_interfaces() { hotspot_iface.append(Some(&iface), &label); }
    if !hotspot_iface.set_active_id(Some(&settings.hotspot_iface)) { hotspot_iface.set_active_id(Some("auto")); }
    let hotspot_vpn_macs = gtk::Entry::builder().text(&settings.hotspot_vpn_macs).placeholder_text("VPN devices: AA:BB:CC:DD:EE:FF,11:22:33:44:55:66").hexpand(true).build();
    let hotspot_direct_macs = gtk::Entry::builder().text(&settings.hotspot_direct_macs).placeholder_text("Direct devices: 77:88:99:AA:BB:CC").hexpand(true).build();
    let recover_network = gtk::CheckButton::with_label("Auto-recover Internet after failed connect / disconnect"); recover_network.set_active(settings.recover_network);
    let reset_tuning = gtk::Button::with_label("Reset Iran tuning");

    let routing_row = gtk::Box::new(Orientation::Horizontal, 10);
    routing_row.append(&gtk::Label::builder().label("Routing mode").width_chars(18).halign(gtk::Align::Start).build()); routing_row.append(&routing_mode);
    let mss_row = gtk::Box::new(Orientation::Horizontal, 10);
    mss_row.append(&gtk::Label::builder().label("TCP MSS").width_chars(18).halign(gtk::Align::Start).build()); mss_row.append(&mss);
    let dns_row = gtk::Box::new(Orientation::Horizontal, 10);
    dns_row.append(&gtk::Label::builder().label("Surfshark DNS").width_chars(18).halign(gtk::Align::Start).build()); dns_row.append(&dns);
    let hotspot_row = gtk::Box::new(Orientation::Horizontal, 10);
    hotspot_row.append(&gtk::Label::builder().label("Hotspot interface").width_chars(18).halign(gtk::Align::Start).build()); hotspot_row.append(&hotspot_iface);

    let settings_box = gtk::Box::new(Orientation::Vertical, 9); settings_box.add_css_class("settings-box");
    settings_box.append(&restricted_mode);
    settings_box.append(&gtk::Separator::new(Orientation::Horizontal));
    settings_box.append(&gtk::Label::builder().label("Surfshark credentials").halign(gtk::Align::Start).css_classes(["heading"]).build());
    settings_box.append(&user); settings_box.append(&pass);
    settings_box.append(&gtk::Label::builder().label("Username is stored in your user config. Service password is stored root-only by the privileged helper after first use.").halign(gtk::Align::Start).wrap(true).css_classes(["dim-label", "small-note"]).build());
    settings_box.append(&gtk::Separator::new(Orientation::Horizontal));
    settings_box.append(&gtk::Label::builder().label("Routing & Iran split").halign(gtk::Align::Start).css_classes(["heading"]).build());
    settings_box.append(&routing_row); settings_box.append(&kill_switch);
    settings_box.append(&gtk::Label::builder().label("Iran Direct marks Iranian IPv4 destinations direct and foreign destinations VPN. DNS stays on the VPN path.").halign(gtk::Align::Start).wrap(true).css_classes(["dim-label", "small-note"]).build());
    settings_box.append(&gtk::Label::builder().label("Iran / restricted-network tuning").halign(gtk::Align::Start).css_classes(["heading"]).build());
    settings_box.append(&mss_row); settings_box.append(&dns_row);
    settings_box.append(&gtk::Label::builder().label("Hotspot routing · per device").halign(gtk::Align::Start).css_classes(["heading"]).build());
    settings_box.append(&hotspot_row); settings_box.append(&hotspot_vpn);
    settings_box.append(&hotspot_vpn_macs); settings_box.append(&hotspot_direct_macs);
    settings_box.append(&gtk::Label::builder().label("Comma-separated MAC addresses. VPN list always forces those devices through Surfshark; Direct list always bypasses Surfshark. Unlisted devices follow the checkbox above. A MAC cannot be in both lists.").halign(gtk::Align::Start).wrap(true).css_classes(["dim-label", "small-note"]).build());
    settings_box.append(&recover_network); settings_box.append(&reset_tuning);
    let settings_expander = gtk::Expander::new(Some("Settings & Iran tuning")); settings_expander.set_child(Some(&settings_box));

    let connect = gtk::Button::with_label("Connect securely"); connect.add_css_class("suggested-action"); connect.add_css_class("primary-connect"); connect.set_visible(!initially_active);
    let disconnect = gtk::Button::with_label("Disconnect"); disconnect.add_css_class("destructive-action"); disconnect.add_css_class("primary-connect"); disconnect.set_visible(initially_active);
    let refresh = gtk::Button::with_label("Refresh status");
    let actions = gtk::Box::new(Orientation::Horizontal, 8); actions.set_halign(gtk::Align::Center); actions.append(&connect); actions.append(&disconnect); actions.append(&refresh);

    let ip_label = gtk::Label::builder().label(state_value("PUBLIC_IP").map(|ip| format!("Public IP: {ip}")).unwrap_or_else(|| "Public IP: —".into())).halign(gtk::Align::Center).css_classes(["dim-label"]).build();
    let hotspot_label = gtk::Label::builder().label(if let Some(iface) = state_value("HOTSPOT_IFACE") { format!("Hotspot: {iface} · per-device policy active") } else { "Hotspot: normal route / inactive".into() }).halign(gtk::Align::Center).css_classes(["dim-label", "small-note"]).build();
    let text_view = gtk::TextView::builder().editable(false).monospace(true).wrap_mode(gtk::WrapMode::WordChar).top_margin(12).bottom_margin(12).left_margin(12).right_margin(12).css_classes(["diag-box"]).build();
    let buffer = text_view.buffer(); buffer.set_text("Surfshark IKEv2 diagnostic log\n");
    let scroller = gtk::ScrolledWindow::builder().vexpand(true).hexpand(true).min_content_height(230).child(&text_view).build();
    let expander = gtk::Expander::new(Some("Advanced diagnostics")); expander.set_child(Some(&scroller));

    let content = gtk::Box::new(Orientation::Vertical, 16); content.set_margin_top(18); content.set_margin_bottom(18); content.set_margin_start(22); content.set_margin_end(22);
    for w in [&hero, &location_box] { content.append(w); }
    content.append(&settings_expander); content.append(&actions); content.append(&ip_label); content.append(&hotspot_label); content.append(&expander);
    let root = gtk::Box::new(Orientation::Vertical, 0); root.append(&header); root.append(&content);
    let window = adw::ApplicationWindow::builder().application(app).title("Surfshark IKEv2 for Linux").default_width(840).default_height(920).content(&root).build();

    let (tx, rx) = mpsc::channel::<Event>();
    let status = Rc::new(status); let status_icon = Rc::new(status_icon); let hero_detail = Rc::new(hero_detail); let spinner = Rc::new(spinner); let progress = Rc::new(progress);
    let connect = Rc::new(connect); let disconnect = Rc::new(disconnect); let refresh = Rc::new(refresh); let ping_button = Rc::new(ping_button); let buffer = Rc::new(buffer); let ip_label = Rc::new(ip_label); let hotspot_label = Rc::new(hotspot_label);
    let pass = Rc::new(pass); let user = Rc::new(user); let location = Rc::new(location); let restricted_mode = Rc::new(restricted_mode); let mss = Rc::new(mss); let dns = Rc::new(dns); let hotspot_vpn = Rc::new(hotspot_vpn); let hotspot_iface = Rc::new(hotspot_iface); let hotspot_vpn_macs = Rc::new(hotspot_vpn_macs); let hotspot_direct_macs = Rc::new(hotspot_direct_macs); let recover_network = Rc::new(recover_network); let kill_switch = Rc::new(kill_switch); let routing_mode = Rc::new(routing_mode);

    {
        let mss = Rc::clone(&mss); let dns = Rc::clone(&dns); let hotspot_vpn = Rc::clone(&hotspot_vpn); let hotspot_iface = Rc::clone(&hotspot_iface); let hotspot_vpn_macs = Rc::clone(&hotspot_vpn_macs); let hotspot_direct_macs = Rc::clone(&hotspot_direct_macs); let recover_network = Rc::clone(&recover_network); let restricted_mode = Rc::clone(&restricted_mode); let kill_switch = Rc::clone(&kill_switch); let routing_mode = Rc::clone(&routing_mode);
        reset_tuning.connect_clicked(move |_| {
            mss.set_value(1200.0); dns.set_text(DEFAULT_DNS); hotspot_vpn.set_active(true); hotspot_iface.set_active_id(Some("auto")); hotspot_vpn_macs.set_text(""); hotspot_direct_macs.set_text(""); recover_network.set_active(true); restricted_mode.set_active(true); kill_switch.set_active(true); routing_mode.set_active_id(Some("vpn_all"));
        });
    }

    {
        let status = Rc::clone(&status); let status_icon = Rc::clone(&status_icon); let hero_detail = Rc::clone(&hero_detail); let spinner = Rc::clone(&spinner); let progress = Rc::clone(&progress);
        let connect = Rc::clone(&connect); let disconnect = Rc::clone(&disconnect); let refresh = Rc::clone(&refresh); let ping_button = Rc::clone(&ping_button); let buffer = Rc::clone(&buffer); let ip_label = Rc::clone(&ip_label); let hotspot_label = Rc::clone(&hotspot_label); let pass = Rc::clone(&pass); let location = Rc::clone(&location);
        glib::timeout_add_local(Duration::from_millis(90), move || {
            if spinner.is_spinning() { progress.pulse(); }
            while let Ok(event) = rx.try_recv() {
                match event {
                    Event::Busy(message) => {
                        status.set_label(&message); hero_detail.set_label("Negotiating secure IKEv2 tunnel…"); status_icon.set_icon_name(Some("network-transmit-receive-symbolic")); spinner.start(); progress.set_visible(true);
                        connect.set_sensitive(false); disconnect.set_sensitive(false); refresh.set_sensitive(false);
                    }
                    Event::Log(title, body) => append_log(&buffer, &title, &body),
                    Event::Connected(ip, label, hotspot) => {
                        spinner.stop(); progress.set_visible(false); status.set_label("Connected"); hero_detail.set_label(&format!("Protected · {label}")); status_icon.set_icon_name(Some("network-vpn-symbolic")); ip_label.set_label(&format!("Public IP: {ip}")); hotspot_label.set_label(&format!("Hotspot: {hotspot}"));
                        connect.set_visible(false); disconnect.set_visible(true); connect.set_sensitive(true); disconnect.set_sensitive(true); refresh.set_sensitive(true); pass.set_text("");
                    }
                    Event::Disconnected => {
                        spinner.stop(); progress.set_visible(false); status.set_label("Disconnected"); hero_detail.set_label("Network restored · ready to connect"); status_icon.set_icon_name(Some("network-offline-symbolic")); ip_label.set_label("Public IP: —"); hotspot_label.set_label("Hotspot: normal route / inactive");
                        connect.set_visible(true); disconnect.set_visible(false); connect.set_sensitive(true); disconnect.set_sensitive(true); refresh.set_sensitive(true);
                    }
                    Event::Failed(message) => {
                        spinner.stop(); progress.set_visible(false); status.set_label("Connection failed"); hero_detail.set_label("Tunnel was not established. Network recovery has been requested."); status_icon.set_icon_name(Some("dialog-warning-symbolic")); connect.set_visible(true); disconnect.set_visible(false); connect.set_sensitive(true); disconnect.set_sensitive(true); refresh.set_sensitive(true); append_log(&buffer, "ERROR", &message);
                    }
                    Event::Refreshed(active, text) => {
                        spinner.stop(); progress.set_visible(false); status.set_label(if active { "Connected" } else { "Disconnected" }); status_icon.set_icon_name(Some(if active { "network-vpn-symbolic" } else { "network-offline-symbolic" })); connect.set_visible(!active); disconnect.set_visible(active); connect.set_sensitive(true); disconnect.set_sensitive(true); refresh.set_sensitive(true); append_log(&buffer, "STATUS", &text);
                    }
                    Event::PingStarted => { ping_button.set_sensitive(false); ping_button.set_label("Testing…"); }
                    Event::PingResults(results) => { ping_button.set_sensitive(true); ping_button.set_label("Test latency"); repopulate_locations(&location, &results); append_log(&buffer, "LATENCY SCAN", &format!("{} of {} locations replied.", results.iter().filter(|(_, ms)| ms.is_some()).count(), results.len())); }
                }
            }
            glib::ControlFlow::Continue
        });
    }

    {
        let tx = tx.clone(); let user = Rc::clone(&user); let pass = Rc::clone(&pass); let location = Rc::clone(&location); let restricted_mode = Rc::clone(&restricted_mode); let mss = Rc::clone(&mss); let dns = Rc::clone(&dns); let hotspot_vpn = Rc::clone(&hotspot_vpn); let hotspot_iface = Rc::clone(&hotspot_iface); let hotspot_vpn_macs = Rc::clone(&hotspot_vpn_macs); let hotspot_direct_macs = Rc::clone(&hotspot_direct_macs); let recover_network = Rc::clone(&recover_network); let kill_switch = Rc::clone(&kill_switch); let routing_mode = Rc::clone(&routing_mode);
        connect.connect_clicked(move |_| {
            let id = location.active_id().map(|s| s.to_string()).unwrap_or_else(|| "ee-tll".to_string());
            let Some(selected) = by_id(&id) else { return; };
            let username = user.text().trim().to_string(); let password = pass.text().to_string();
            if username.is_empty() { let _ = tx.send(Event::Failed("Surfshark service username is required in Settings.".into())); return; }
            let vpn_macs = normalize_mac_csv(hotspot_vpn_macs.text().as_str());
            let direct_macs = normalize_mac_csv(hotspot_direct_macs.text().as_str());
            let current = AppSettings {
                restricted: restricted_mode.is_active(),
                mss: mss.value_as_int().clamp(900, 1400) as u32,
                dns: if dns.text().trim().is_empty() { DEFAULT_DNS.to_string() } else { dns.text().trim().to_string() },
                hotspot_vpn: hotspot_vpn.is_active(),
                hotspot_iface: hotspot_iface.active_id().map(|s| s.to_string()).unwrap_or_else(|| "auto".into()),
                recover_network: recover_network.is_active(),
                kill_switch: kill_switch.is_active(),
                routing_mode: routing_mode.active_id().map(|s| s.to_string()).unwrap_or_else(|| "vpn_all".into()),
                hotspot_vpn_macs: vpn_macs,
                hotspot_direct_macs: direct_macs,
            };
            save_username(&username); save_settings(&current);
            let tx = tx.clone();
            thread::spawn(move || {
                let _ = tx.send(Event::Busy(format!("Connecting to {}…", selected.city)));
                if current.restricted {
                    if nm_active() { let _ = nm(&["--wait", "5", "connection", "down", PROFILE]); }
                    let candidates = restricted_candidates(selected.host);
                    let _ = tx.send(Event::Log("RESTRICTED ENDPOINTS".into(), format!("{} candidate(s):\n{}\nMSS={}\nDNS={}\nRouting mode={}\nKill switch={}\nHotspot default VPN={}\nHotspot interface={}\nVPN MACs={}\nDirect MACs={}\nAuto recovery={}", candidates.len(), candidates.join("\n"), current.mss, current.dns, current.routing_mode, current.kill_switch, current.hotspot_vpn, current.hotspot_iface, if current.hotspot_vpn_macs.is_empty() { "—" } else { &current.hotspot_vpn_macs }, if current.hotspot_direct_macs.is_empty() { "—" } else { &current.hotspot_direct_macs }, current.recover_network)));
                    if candidates.is_empty() { let _ = tx.send(Event::Failed("No bundled restricted endpoint exists for this location yet.".into())); return; }
                    for (i, endpoint) in candidates.iter().enumerate() {
                        let _ = tx.send(Event::Busy(format!("{} · secure route {}/{}…", selected.city, i + 1, candidates.len())));
                        let (ok, log) = restricted_connect(endpoint, &username, &password, &current);
                        let _ = tx.send(Event::Log(format!("RESTRICTED ATTEMPT {}/{}", i + 1, candidates.len()), log.clone()));
                        if ok {
                            let ip = parse_helper_value(&log, "Public IPv4").unwrap_or_else(|| "connected".into());
                            let country = parse_helper_value(&log, "Exit country").unwrap_or_default();
                            let hotspot = parse_helper_value(&log, "Device policy").or_else(|| parse_helper_value(&log, "Hotspot VPN")).unwrap_or_else(|| "default policy".into());
                            let mode = parse_helper_value(&log, "Routing mode").unwrap_or_else(|| current.routing_mode.clone());
                            let label = if country.is_empty() { format!("{} · {}", selected.label, mode) } else { format!("{} · {} · {}", selected.label, country, mode) };
                            let _ = tx.send(Event::Connected(ip, label, hotspot)); return;
                        }
                    }
                    let _ = restricted_disconnect();
                    let _ = tx.send(Event::Failed(format!("All {} restricted endpoint candidate(s) failed.", candidates.len())));
                } else {
                    if restricted_active() { let _ = restricted_disconnect(); }
                    let pass_opt = if password.is_empty() { None } else { Some(password.as_str()) };
                    let (ok, log) = standard_connect(selected.host, &username, pass_opt);
                    let _ = tx.send(Event::Log("NETWORKMANAGER CONNECT".into(), log));
                    if ok { let _ = tx.send(Event::Connected(public_ip().trim().to_string(), selected.label.to_string(), "normal route".into())); }
                    else { let _ = tx.send(Event::Failed("NetworkManager IKEv2 activation failed.".into())); }
                }
            });
        });
    }

    {
        let tx = tx.clone();
        disconnect.connect_clicked(move |_| {
            let tx = tx.clone();
            thread::spawn(move || {
                let _ = tx.send(Event::Busy("Disconnecting & restoring network…".into()));
                let mut log = String::new();
                if restricted_active() || fs::metadata(RESTRICTED_STATE).is_ok() { log.push_str(&restricted_disconnect()); log.push('\n'); }
                if nm_active() { log.push_str(&nm(&["--wait", "5", "connection", "down", PROFILE])); }
                let _ = tx.send(Event::Log("DISCONNECT".into(), log));
                let _ = tx.send(if any_vpn_active() { Event::Failed("VPN still appears active after cleanup.".into()) } else { Event::Disconnected });
            });
        });
    }

    {
        let tx = tx.clone();
        refresh.connect_clicked(move |_| {
            let tx = tx.clone();
            thread::spawn(move || {
                let _ = tx.send(Event::Busy("Refreshing status…".into()));
                let active = any_vpn_active();
                let text = format!("restricted_active={}\nnetworkmanager_active={}\nvirtual_ip={}\npublic_ip={}\nrouting_mode={}\nkill_switch={}\niran_prefixes={}\nhotspot_target={}\nhotspot_iface={}\nhotspot_policy_active={}\nvpn_device_count={}\ndirect_device_count={}", restricted_active(), nm_active(), state_value("VIRTUAL_IP").unwrap_or_else(|| "—".into()), state_value("PUBLIC_IP").unwrap_or_else(|| if active { public_ip() } else { "—".into() }), state_value("ROUTING_MODE").unwrap_or_else(|| "—".into()), state_value("KILL_SWITCH").unwrap_or_else(|| "—".into()), state_value("IRAN_SET_ENTRIES").unwrap_or_else(|| "0".into()), state_value("HOTSPOT_IFACE_REQUEST").unwrap_or_else(|| "auto".into()), state_value("HOTSPOT_IFACE").unwrap_or_else(|| "—".into()), state_value("HOTSPOT_POLICY_ACTIVE").unwrap_or_else(|| "0".into()), state_value("HOTSPOT_VPN_MAC_COUNT").unwrap_or_else(|| "0".into()), state_value("HOTSPOT_DIRECT_MAC_COUNT").unwrap_or_else(|| "0".into()));
                let _ = tx.send(Event::Refreshed(active, text));
            });
        });
    }

    {
        let tx = tx.clone(); ping_button.connect_clicked(move |_| { let tx = tx.clone(); thread::spawn(move || { let _ = tx.send(Event::PingStarted); let _ = tx.send(Event::PingResults(scan_latencies())); }); });
    }

    window.present();
}
