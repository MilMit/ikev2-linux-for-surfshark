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
const LIVE_STATE: &str = "/run/milmit-surfshark/live.state";
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

fn file_value(path: &str, key: &str) -> Option<String> {
    let state = fs::read_to_string(path).ok()?;
    state.lines().find_map(|line| {
        let (k, v) = line.split_once('=')?;
        (k == key).then(|| v.trim().to_string())
    }).filter(|v| !v.is_empty())
}
fn state_value(key: &str) -> Option<String> { file_value(RESTRICTED_STATE, key) }
fn live_value(key: &str) -> Option<String> { file_value(LIVE_STATE, key) }

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
        settings.restricted as u8, settings.mss, settings.dns, settings.hotspot_vpn as u8,
        settings.hotspot_iface, settings.recover_network as u8, settings.kill_switch as u8,
        settings.routing_mode, settings.hotspot_vpn_macs, settings.hotspot_direct_macs,
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
        let icon = if kind == "wifi" { "◉" } else { "◆" };
        out.push((dev.to_string(), format!("{icon} {dev}  ·  {kind}  ·  {state}")));
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
        Ok(out) => { log.push_str(&String::from_utf8_lossy(&out.stdout)); log.push_str(&String::from_utf8_lossy(&out.stderr)); }
        Err(e) => log.push_str(&format!("nmcli failed: {e}")),
    }
    log
}
fn standard_connect(host: &str, username: &str, password: Option<&str>) -> (bool, String) {
    if nm_active() { let _ = nm(&["--wait", "5", "connection", "down", PROFILE]); }
    let mut log = configure_nm_profile(host, host, username, password);
    log.push('\n'); log.push_str(&nm(&["--wait", "15", "connection", "up", PROFILE]));
    (nm_active(), log)
}
fn restricted_candidates(host: &str) -> Vec<String> {
    let mut out = Vec::new();
    if host == "ee-tll.prod.surfshark.com" { out.push("185.174.159.123".to_string()); }
    for ip in bundled_for_host(host) { if !out.iter().any(|v| v == ip) { out.push((*ip).to_string()); } }
    out
}
fn restricted_connect(endpoint: &str, username: &str, password: &str, settings: &AppSettings) -> (bool, String) {
    let mss = settings.mss.to_string();
    let hotspot = if settings.hotspot_vpn { "1" } else { "0" };
    let recover = if settings.recover_network { "1" } else { "0" };
    let kill = if settings.kill_switch { "1" } else { "0" };
    let mut child = match Command::new("pkexec")
        .arg("bash").arg(RESTRICTED_CONNECT).arg(endpoint).arg(username).arg(&mss)
        .arg(&settings.dns).arg(hotspot).arg(recover).arg(&settings.hotspot_iface).arg(kill)
        .arg(&settings.routing_mode).arg(&settings.hotspot_vpn_macs).arg(&settings.hotspot_direct_macs)
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn() {
        Ok(child) => child,
        Err(e) => return (false, format!("Could not start restricted helper: {e}")),
    };
    if let Some(stdin) = child.stdin.as_mut() { let _ = writeln!(stdin, "{password}"); }
    match child.wait_with_output() {
        Ok(out) => {
            let mut text = String::from_utf8_lossy(&out.stdout).to_string();
            if !out.stderr.is_empty() { if !text.is_empty() { text.push('\n'); } text.push_str(&String::from_utf8_lossy(&out.stderr)); }
            (out.status.success() && text.contains("Data-path test: OK"), text)
        }
        Err(e) => (false, format!("Restricted helper failed: {e}")),
    }
}
fn restricted_disconnect() -> String { run("pkexec", &["bash", RESTRICTED_DISCONNECT]) }
fn parse_helper_value(text: &str, key: &str) -> Option<String> {
    text.lines().find_map(|line| { let (k, v) = line.split_once(':')?; (k.trim() == key).then(|| v.trim().to_string()) }).filter(|v| !v.is_empty())
}
fn ping_ms(host: &str) -> Option<u32> {
    let target = if host == "ee-tll.prod.surfshark.com" { "185.174.159.123" } else { bundled_for_host(host).first().copied().unwrap_or(host) };
    let output = Command::new("ping").args(["-n", "-c", "1", "-W", "1", target]).output().ok()?;
    if !output.status.success() { return None; }
    let text = String::from_utf8_lossy(&output.stdout); let start = text.find("time=")? + 5; let rest = &text[start..];
    let end = rest.find(|c: char| c == ' ' || c == '\n').unwrap_or(rest.len());
    rest[..end].parse::<f64>().ok().map(|v| v.round() as u32)
}
fn scan_latencies() -> Vec<(String, Option<u32>)> { LOCATIONS.iter().map(|item| (item.id.to_string(), ping_ms(item.host))).collect() }
fn repopulate_locations(combo: &gtk::ComboBoxText, results: &[(String, Option<u32>)]) {
    let active = combo.active_id().map(|s| s.to_string()); combo.remove_all();
    for item in LOCATIONS {
        let latency = results.iter().find(|(id, _)| id == item.id).and_then(|(_, value)| *value);
        let label = match latency { Some(ms) if ms < 100 => format!("●  {}  ·  {} ms", item.label, ms), Some(ms) if ms < 220 => format!("◐  {}  ·  {} ms", item.label, ms), Some(ms) => format!("○  {}  ·  {} ms", item.label, ms), None => format!("·  {}  ·  no ping", item.label) };
        combo.append(Some(item.id), &label);
    }
    if let Some(id) = active { combo.set_active_id(Some(&id)); } else { combo.set_active(Some(0)); }
}
fn append_log(buffer: &gtk::TextBuffer, title: &str, body: &str) {
    let mut end = buffer.end_iter(); buffer.insert(&mut end, &format!("\n╭─ {title}\n{body}\n╰────────────────────────\n"));
}
fn fmt_rate(raw: Option<String>) -> String {
    let n = raw.and_then(|v| v.parse::<f64>().ok()).unwrap_or(0.0);
    if n >= 1_048_576.0 { format!("{:.1} MB/s", n / 1_048_576.0) }
    else if n >= 1024.0 { format!("{:.0} KB/s", n / 1024.0) } else { format!("{:.0} B/s", n) }
}

fn install_css() {
    let provider = gtk::CssProvider::new();
    provider.load_from_data(
        "window { background: @window_bg_color; }\n\
         .shell { background: linear-gradient(145deg, alpha(@window_bg_color,.98), alpha(@view_bg_color,.90)); }\n\
         .sidebar { min-width: 172px; padding: 18px 12px; background: alpha(@card_bg_color,.62); border-right: 1px solid alpha(@borders,.50); }\n\
         .brand { font-size: 18px; font-weight: 900; letter-spacing: .8px; }\n\
         .brand-sub { font-size: 10px; opacity: .62; }\n\
         .nav-button { min-height: 42px; padding: 0 14px; border-radius: 12px; background: transparent; box-shadow: none; }\n\
         .nav-button:hover { background: alpha(@accent_bg_color,.11); }\n\
         .nav-active { background: alpha(@accent_bg_color,.18); font-weight: 800; }\n\
         .page { padding: 22px 26px 26px 26px; }\n\
         .hero-card { padding: 24px; border-radius: 24px; background: linear-gradient(135deg, alpha(@accent_bg_color,.16), alpha(@card_bg_color,.68)); border: 1px solid alpha(@accent_bg_color,.20); }\n\
         .hero-title { font-size: 26px; font-weight: 900; letter-spacing: -.4px; }\n\
         .hero-subtitle { font-size: 12px; opacity: .66; }\n\
         .orb { min-width: 164px; min-height: 164px; border-radius: 999px; background: radial-gradient(circle, alpha(@accent_bg_color,.28), alpha(@accent_bg_color,.08)); border: 2px solid alpha(@accent_bg_color,.48); box-shadow: 0 0 24px alpha(@accent_bg_color,.16); }\n\
         .orb-connected { background: radial-gradient(circle, alpha(@success_color,.30), alpha(@success_color,.08)); border-color: alpha(@success_color,.58); }\n\
         .orb-busy { background: radial-gradient(circle, alpha(@accent_bg_color,.34), alpha(@accent_bg_color,.10)); border-color: alpha(@accent_bg_color,.78); }\n\
         .orb-error { background: radial-gradient(circle, alpha(@error_color,.24), alpha(@error_color,.06)); border-color: alpha(@error_color,.58); }\n\
         .orb-icon { -gtk-icon-size: 56px; }\n\
         .status-title { font-size: 20px; font-weight: 900; }\n\
         .status-detail { font-size: 11px; opacity: .68; }\n\
         .connect-btn { min-height: 48px; min-width: 190px; padding: 0 28px; border-radius: 999px; font-weight: 900; }\n\
         .metric { padding: 13px 15px; border-radius: 15px; background: alpha(@card_bg_color,.70); border: 1px solid alpha(@borders,.45); }\n\
         .metric-value { font-size: 15px; font-weight: 800; }\n\
         .metric-name { font-size: 10px; opacity: .60; }\n\
         .section-card { padding: 16px; border-radius: 18px; background: alpha(@card_bg_color,.68); border: 1px solid alpha(@borders,.44); }\n\
         .section-title { font-size: 14px; font-weight: 850; }\n\
         .section-sub { font-size: 10px; opacity: .62; }\n\
         .soft-pill { padding: 6px 10px; border-radius: 999px; background: alpha(@accent_bg_color,.12); font-size: 10px; font-weight: 700; }\n\
         .tiny { font-size: 10px; opacity: .62; }\n\
         .diag { font-size: 11px; padding: 12px; }\n\
         .progress-rail trough { min-height: 5px; border-radius: 999px; }\n\
         .progress-rail progress { min-height: 5px; border-radius: 999px; }\n\
         entry, spinbutton, combobox button { min-height: 38px; border-radius: 10px; }"
    );
    if let Some(display) = gtk::gdk::Display::default() { gtk::style_context_add_provider_for_display(&display, &provider, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION); }
}

fn metric_card(title: &str, value: &gtk::Label) -> gtk::Box {
    let boxx = gtk::Box::new(Orientation::Vertical, 3); boxx.add_css_class("metric"); boxx.set_hexpand(true);
    value.add_css_class("metric-value");
    boxx.append(value); boxx.append(&gtk::Label::builder().label(title).halign(gtk::Align::Start).css_classes(["metric-name"]).build()); boxx
}
fn section_header(title: &str, sub: &str) -> gtk::Box {
    let b = gtk::Box::new(Orientation::Vertical, 2);
    b.append(&gtk::Label::builder().label(title).halign(gtk::Align::Start).css_classes(["section-title"]).build());
    b.append(&gtk::Label::builder().label(sub).halign(gtk::Align::Start).css_classes(["section-sub"]).build()); b
}

fn main() -> glib::ExitCode {
    let app = adw::Application::builder().application_id("net.milmit.SurfsharkIkev2").build();
    app.connect_activate(build_ui); app.run()
}

fn build_ui(app: &adw::Application) {
    install_css();
    let settings = load_settings();
    let initially_active = any_vpn_active();

    let header = adw::HeaderBar::new();
    header.set_title_widget(Some(&adw::WindowTitle::new("MilMit Secure", "Surfshark IKEv2 · Linux")));

    let status_icon = gtk::Image::from_icon_name(if initially_active { "network-vpn-symbolic" } else { "network-offline-symbolic" });
    status_icon.add_css_class("orb-icon");
    let orb = gtk::Box::new(Orientation::Vertical, 0); orb.set_halign(gtk::Align::Center); orb.set_valign(gtk::Align::Center); orb.add_css_class("orb"); if initially_active { orb.add_css_class("orb-connected"); } orb.append(&status_icon);
    let status = gtk::Label::builder().label(if initially_active { "Connected" } else { "Ready" }).css_classes(["status-title"]).build();
    let hero_detail = gtk::Label::builder().label(if initially_active { "Encrypted IKEv2 tunnel active" } else { "Choose a location and start protection" }).css_classes(["status-detail"]).build();
    let spinner = gtk::Spinner::new();
    let progress = gtk::ProgressBar::new(); progress.add_css_class("progress-rail"); progress.set_visible(false); progress.set_pulse_step(0.08);

    let connect = gtk::Button::with_label("Connect securely"); connect.add_css_class("suggested-action"); connect.add_css_class("connect-btn"); connect.set_visible(!initially_active);
    let disconnect = gtk::Button::with_label("Disconnect"); disconnect.add_css_class("destructive-action"); disconnect.add_css_class("connect-btn"); disconnect.set_visible(initially_active);
    let refresh = gtk::Button::from_icon_name("view-refresh-symbolic"); refresh.set_tooltip_text(Some("Refresh status"));

    let public_value = gtk::Label::builder().label(state_value("PUBLIC_IP").unwrap_or_else(|| "—".into())).halign(gtk::Align::Start).build();
    let down_value = gtk::Label::builder().label("0 B/s").halign(gtk::Align::Start).build();
    let up_value = gtk::Label::builder().label("0 B/s").halign(gtk::Align::Start).build();
    let ping_value = gtk::Label::builder().label("— ms").halign(gtk::Align::Start).build();

    let metrics = gtk::Box::new(Orientation::Horizontal, 10);
    metrics.append(&metric_card("PUBLIC IP", &public_value)); metrics.append(&metric_card("DOWNLOAD", &down_value)); metrics.append(&metric_card("UPLOAD", &up_value)); metrics.append(&metric_card("LATENCY", &ping_value));

    let hero_actions = gtk::Box::new(Orientation::Horizontal, 8); hero_actions.set_halign(gtk::Align::Center); hero_actions.append(&connect); hero_actions.append(&disconnect); hero_actions.append(&refresh);
    let hero = gtk::Box::new(Orientation::Vertical, 10); hero.add_css_class("hero-card"); hero.set_halign(gtk::Align::Fill);
    hero.append(&orb); hero.append(&status); hero.append(&hero_detail); hero.append(&spinner); hero.append(&progress); hero.append(&hero_actions); hero.append(&metrics);

    let location = gtk::ComboBoxText::new(); location.set_hexpand(true); for item in LOCATIONS { location.append(Some(item.id), item.label); } location.set_active_id(Some("ee-tll"));
    let ping_button = gtk::Button::with_label("Scan latency");
    let loc_row = gtk::Box::new(Orientation::Horizontal, 8); loc_row.append(&location); loc_row.append(&ping_button);
    let location_card = gtk::Box::new(Orientation::Vertical, 10); location_card.add_css_class("section-card"); location_card.append(&section_header("Location", "Select a Surfshark region or scan all locations")); location_card.append(&loc_row);

    let watchdog_value = gtk::Label::builder().label("Waiting").css_classes(["soft-pill"]).build();
    let route_value = gtk::Label::builder().label(state_value("ROUTING_MODE").unwrap_or_else(|| "VPN everything".into())).css_classes(["soft-pill"]).build();
    let hotspot_value = gtk::Label::builder().label(state_value("HOTSPOT_IFACE").unwrap_or_else(|| "Off".into())).css_classes(["soft-pill"]).build();
    let health_row = gtk::Box::new(Orientation::Horizontal, 8); health_row.set_halign(gtk::Align::Center); health_row.append(&watchdog_value); health_row.append(&route_value); health_row.append(&hotspot_value);
    let health_card = gtk::Box::new(Orientation::Vertical, 10); health_card.add_css_class("section-card"); health_card.append(&section_header("Live protection", "Watchdog, policy routing and hotspot state")); health_card.append(&health_row);

    let dashboard = gtk::Box::new(Orientation::Vertical, 14); dashboard.add_css_class("page"); dashboard.append(&hero); dashboard.append(&location_card); dashboard.append(&health_card);

    let restricted_mode = gtk::CheckButton::with_label("Restricted network / Iran compatibility mode"); restricted_mode.set_active(settings.restricted);
    let user = gtk::Entry::builder().placeholder_text("Surfshark service username").hexpand(true).build(); if let Some(name) = saved_username() { user.set_text(&name); }
    let pass = gtk::PasswordEntry::builder().placeholder_text("Service password · blank = use saved").show_peek_icon(true).hexpand(true).build();
    let mss = gtk::SpinButton::with_range(900.0, 1400.0, 10.0); mss.set_value(settings.mss as f64);
    let dns = gtk::Entry::builder().text(&settings.dns).placeholder_text(DEFAULT_DNS).hexpand(true).build();
    let routing_mode = gtk::ComboBoxText::new(); routing_mode.set_hexpand(true); routing_mode.append(Some("vpn_all"), "VPN Everything"); routing_mode.append(Some("iran_direct"), "Iran Direct · Foreign through VPN"); routing_mode.set_active_id(Some(&settings.routing_mode));
    let kill_switch = gtk::CheckButton::with_label("Kill Switch · block public traffic if VPN path fails"); kill_switch.set_active(settings.kill_switch);
    let hotspot_vpn = gtk::CheckButton::with_label("Unlisted hotspot devices use VPN policy"); hotspot_vpn.set_active(settings.hotspot_vpn);
    let hotspot_iface = gtk::ComboBoxText::new(); hotspot_iface.set_hexpand(true); hotspot_iface.append(Some("auto"), "Auto-detect active hotspot"); for (iface, label) in network_interfaces() { hotspot_iface.append(Some(&iface), &label); } if !hotspot_iface.set_active_id(Some(&settings.hotspot_iface)) { hotspot_iface.set_active_id(Some("auto")); }
    let hotspot_vpn_macs = gtk::Entry::builder().text(&settings.hotspot_vpn_macs).placeholder_text("VPN devices · MAC addresses").hexpand(true).build();
    let hotspot_direct_macs = gtk::Entry::builder().text(&settings.hotspot_direct_macs).placeholder_text("Direct devices · MAC addresses").hexpand(true).build();
    let recover_network = gtk::CheckButton::with_label("Auto-recover network after failed connect / disconnect"); recover_network.set_active(settings.recover_network);
    let reset_tuning = gtk::Button::with_label("Reset recommended values");

    let credentials_card = gtk::Box::new(Orientation::Vertical, 10); credentials_card.add_css_class("section-card"); credentials_card.append(&section_header("Surfshark credentials", "Stored locally; password is kept by the root-owned helper")); credentials_card.append(&user); credentials_card.append(&pass);
    let routing_card = gtk::Box::new(Orientation::Vertical, 10); routing_card.add_css_class("section-card"); routing_card.append(&section_header("Routing & protection", "Iran-aware policy routing with optional leak protection")); routing_card.append(&routing_mode); routing_card.append(&kill_switch); routing_card.append(&restricted_mode);
    let iran_card = gtk::Box::new(Orientation::Vertical, 10); iran_card.add_css_class("section-card"); iran_card.append(&section_header("Iran tuning", "Safe defaults for filtered and mobile networks"));
    let mss_row = gtk::Box::new(Orientation::Horizontal, 8); mss_row.append(&gtk::Label::builder().label("TCP MSS").width_chars(14).halign(gtk::Align::Start).build()); mss_row.append(&mss); iran_card.append(&mss_row); iran_card.append(&dns); iran_card.append(&recover_network);
    let hotspot_card = gtk::Box::new(Orientation::Vertical, 10); hotspot_card.add_css_class("section-card"); hotspot_card.append(&section_header("Hotspot & devices", "Choose an interface and route devices individually")); hotspot_card.append(&hotspot_iface); hotspot_card.append(&hotspot_vpn); hotspot_card.append(&hotspot_vpn_macs); hotspot_card.append(&hotspot_direct_macs);
    let settings_page = gtk::Box::new(Orientation::Vertical, 14); settings_page.add_css_class("page"); settings_page.append(&credentials_card); settings_page.append(&routing_card); settings_page.append(&iran_card); settings_page.append(&hotspot_card); settings_page.append(&reset_tuning);

    let text_view = gtk::TextView::builder().editable(false).monospace(true).wrap_mode(gtk::WrapMode::WordChar).top_margin(12).bottom_margin(12).left_margin(12).right_margin(12).css_classes(["diag"]).build();
    let buffer = text_view.buffer(); buffer.set_text("MilMit Surfshark IKEv2 diagnostics\n");
    let diag_scroll = gtk::ScrolledWindow::builder().vexpand(true).hexpand(true).child(&text_view).build();
    let diag_card = gtk::Box::new(Orientation::Vertical, 10); diag_card.add_css_class("section-card"); diag_card.append(&section_header("Advanced diagnostics", "Raw backend output for troubleshooting")); diag_card.append(&diag_scroll);
    let diag_page = gtk::Box::new(Orientation::Vertical, 14); diag_page.add_css_class("page"); diag_page.append(&diag_card);

    let stack = gtk::Stack::new(); stack.set_transition_type(gtk::StackTransitionType::SlideLeftRight); stack.set_transition_duration(260); stack.set_hexpand(true); stack.set_vexpand(true); stack.add_named(&dashboard, Some("dashboard")); stack.add_named(&settings_page, Some("settings")); stack.add_named(&diag_page, Some("diagnostics")); stack.set_visible_child_name("dashboard");

    let brand = gtk::Box::new(Orientation::Vertical, 0); brand.append(&gtk::Label::builder().label("MILMIT").halign(gtk::Align::Start).css_classes(["brand"]).build()); brand.append(&gtk::Label::builder().label("SECURE ROUTER").halign(gtk::Align::Start).css_classes(["brand-sub"]).build());
    let nav_dash = gtk::Button::with_label("◉   Dashboard"); let nav_settings = gtk::Button::with_label("⚙   Settings"); let nav_diag = gtk::Button::with_label("⌁   Diagnostics");
    for b in [&nav_dash, &nav_settings, &nav_diag] { b.add_css_class("nav-button"); b.set_halign(gtk::Align::Fill); }
    nav_dash.add_css_class("nav-active");
    let sidebar = gtk::Box::new(Orientation::Vertical, 10); sidebar.add_css_class("sidebar"); sidebar.append(&brand); sidebar.append(&gtk::Separator::new(Orientation::Horizontal)); sidebar.append(&nav_dash); sidebar.append(&nav_settings); sidebar.append(&nav_diag);
    let spacer = gtk::Box::new(Orientation::Vertical, 0); spacer.set_vexpand(true); sidebar.append(&spacer); sidebar.append(&gtk::Label::builder().label("IKEv2 · strongSwan\nIran-ready routing").halign(gtk::Align::Start).css_classes(["tiny"]).build());

    let shell = gtk::Box::new(Orientation::Horizontal, 0); shell.add_css_class("shell"); shell.append(&sidebar); shell.append(&stack);
    let root = gtk::Box::new(Orientation::Vertical, 0); root.append(&header); root.append(&shell);
    let window = adw::ApplicationWindow::builder().application(app).title("MilMit Secure · Surfshark IKEv2").default_width(980).default_height(780).content(&root).build();

    {
        let stack = stack.clone(); let a=nav_dash.clone(); let b=nav_settings.clone(); let c=nav_diag.clone(); nav_dash.connect_clicked(move |_| { stack.set_visible_child_name("dashboard"); a.add_css_class("nav-active"); b.remove_css_class("nav-active"); c.remove_css_class("nav-active"); });
    }
    {
        let stack = stack.clone(); let a=nav_dash.clone(); let b=nav_settings.clone(); let c=nav_diag.clone(); nav_settings.connect_clicked(move |_| { stack.set_visible_child_name("settings"); a.remove_css_class("nav-active"); b.add_css_class("nav-active"); c.remove_css_class("nav-active"); });
    }
    {
        let stack = stack.clone(); let a=nav_dash.clone(); let b=nav_settings.clone(); let c=nav_diag.clone(); nav_diag.connect_clicked(move |_| { stack.set_visible_child_name("diagnostics"); a.remove_css_class("nav-active"); b.remove_css_class("nav-active"); c.add_css_class("nav-active"); });
    }

    let (tx, rx) = mpsc::channel::<Event>();
    let status=Rc::new(status); let status_icon=Rc::new(status_icon); let hero_detail=Rc::new(hero_detail); let spinner=Rc::new(spinner); let progress=Rc::new(progress); let orb=Rc::new(orb);
    let connect=Rc::new(connect); let disconnect=Rc::new(disconnect); let refresh=Rc::new(refresh); let ping_button=Rc::new(ping_button); let buffer=Rc::new(buffer);
    let public_value=Rc::new(public_value); let down_value=Rc::new(down_value); let up_value=Rc::new(up_value); let ping_value=Rc::new(ping_value); let watchdog_value=Rc::new(watchdog_value); let route_value=Rc::new(route_value); let hotspot_value=Rc::new(hotspot_value);
    let pass=Rc::new(pass); let user=Rc::new(user); let location=Rc::new(location); let restricted_mode=Rc::new(restricted_mode); let mss=Rc::new(mss); let dns=Rc::new(dns); let hotspot_vpn=Rc::new(hotspot_vpn); let hotspot_iface=Rc::new(hotspot_iface); let hotspot_vpn_macs=Rc::new(hotspot_vpn_macs); let hotspot_direct_macs=Rc::new(hotspot_direct_macs); let recover_network=Rc::new(recover_network); let kill_switch=Rc::new(kill_switch); let routing_mode=Rc::new(routing_mode);

    {
        let mss=Rc::clone(&mss); let dns=Rc::clone(&dns); let hotspot_vpn=Rc::clone(&hotspot_vpn); let hotspot_iface=Rc::clone(&hotspot_iface); let hotspot_vpn_macs=Rc::clone(&hotspot_vpn_macs); let hotspot_direct_macs=Rc::clone(&hotspot_direct_macs); let recover_network=Rc::clone(&recover_network); let restricted_mode=Rc::clone(&restricted_mode); let kill_switch=Rc::clone(&kill_switch); let routing_mode=Rc::clone(&routing_mode);
        reset_tuning.connect_clicked(move |_| { mss.set_value(1200.0); dns.set_text(DEFAULT_DNS); hotspot_vpn.set_active(true); hotspot_iface.set_active_id(Some("auto")); hotspot_vpn_macs.set_text(""); hotspot_direct_macs.set_text(""); recover_network.set_active(true); restricted_mode.set_active(true); kill_switch.set_active(true); routing_mode.set_active_id(Some("vpn_all")); });
    }

    {
        let status=Rc::clone(&status); let status_icon=Rc::clone(&status_icon); let hero_detail=Rc::clone(&hero_detail); let spinner=Rc::clone(&spinner); let progress=Rc::clone(&progress); let orb=Rc::clone(&orb); let connect=Rc::clone(&connect); let disconnect=Rc::clone(&disconnect); let refresh=Rc::clone(&refresh); let ping_button=Rc::clone(&ping_button); let buffer=Rc::clone(&buffer); let public_value=Rc::clone(&public_value); let down_value=Rc::clone(&down_value); let up_value=Rc::clone(&up_value); let ping_value=Rc::clone(&ping_value); let watchdog_value=Rc::clone(&watchdog_value); let route_value=Rc::clone(&route_value); let hotspot_value=Rc::clone(&hotspot_value); let pass=Rc::clone(&pass); let location=Rc::clone(&location);
        glib::timeout_add_local(Duration::from_millis(110), move || {
            if spinner.is_spinning() { progress.pulse(); }
            down_value.set_label(&fmt_rate(live_value("RX_BPS"))); up_value.set_label(&fmt_rate(live_value("TX_BPS")));
            let lat=live_value("LATENCY_MS").unwrap_or_else(|| "—".into());
            let latency_label = if lat == "0" { "— ms".to_string() } else { format!("{lat} ms") };
            ping_value.set_label(&latency_label);
            watchdog_value.set_label(&format!("Watchdog · {}", live_value("HEALTH").unwrap_or_else(|| "waiting".into())));
            route_value.set_label(&format!("Route · {}", state_value("ROUTING_MODE").unwrap_or_else(|| "—".into())));
            hotspot_value.set_label(&format!("Hotspot · {}", state_value("HOTSPOT_IFACE").unwrap_or_else(|| "off".into())));
            while let Ok(event)=rx.try_recv() {
                match event {
                    Event::Busy(message)=>{ status.set_label(&message); hero_detail.set_label("Negotiating tunnel and policy route…"); status_icon.set_icon_name(Some("network-transmit-receive-symbolic")); spinner.start(); progress.set_visible(true); orb.remove_css_class("orb-connected"); orb.remove_css_class("orb-error"); orb.add_css_class("orb-busy"); connect.set_sensitive(false); disconnect.set_sensitive(false); refresh.set_sensitive(false); }
                    Event::Log(title,body)=>append_log(&buffer,&title,&body),
                    Event::Connected(ip,label,hotspot)=>{ spinner.stop(); progress.set_visible(false); status.set_label("Protected"); hero_detail.set_label(&label); status_icon.set_icon_name(Some("network-vpn-symbolic")); public_value.set_label(&ip); hotspot_value.set_label(&format!("Hotspot · {hotspot}")); orb.remove_css_class("orb-busy"); orb.remove_css_class("orb-error"); orb.add_css_class("orb-connected"); connect.set_visible(false); disconnect.set_visible(true); connect.set_sensitive(true); disconnect.set_sensitive(true); refresh.set_sensitive(true); pass.set_text(""); }
                    Event::Disconnected=>{ spinner.stop(); progress.set_visible(false); status.set_label("Disconnected"); hero_detail.set_label("Network restored · ready to connect"); status_icon.set_icon_name(Some("network-offline-symbolic")); public_value.set_label("—"); orb.remove_css_class("orb-connected"); orb.remove_css_class("orb-busy"); orb.remove_css_class("orb-error"); connect.set_visible(true); disconnect.set_visible(false); connect.set_sensitive(true); disconnect.set_sensitive(true); refresh.set_sensitive(true); }
                    Event::Failed(message)=>{ spinner.stop(); progress.set_visible(false); status.set_label("Connection failed"); hero_detail.set_label("Backend recovered the network. Check diagnostics."); status_icon.set_icon_name(Some("dialog-warning-symbolic")); orb.remove_css_class("orb-connected"); orb.remove_css_class("orb-busy"); orb.add_css_class("orb-error"); connect.set_visible(true); disconnect.set_visible(false); connect.set_sensitive(true); disconnect.set_sensitive(true); refresh.set_sensitive(true); append_log(&buffer,"ERROR",&message); }
                    Event::Refreshed(active,text)=>{ spinner.stop(); progress.set_visible(false); status.set_label(if active{"Protected"}else{"Disconnected"}); status_icon.set_icon_name(Some(if active{"network-vpn-symbolic"}else{"network-offline-symbolic"})); if active { orb.add_css_class("orb-connected"); } else { orb.remove_css_class("orb-connected"); } connect.set_visible(!active); disconnect.set_visible(active); connect.set_sensitive(true); disconnect.set_sensitive(true); refresh.set_sensitive(true); append_log(&buffer,"STATUS",&text); }
                    Event::PingStarted=>{ ping_button.set_sensitive(false); ping_button.set_label("Scanning…"); }
                    Event::PingResults(results)=>{ ping_button.set_sensitive(true); ping_button.set_label("Scan latency"); repopulate_locations(&location,&results); append_log(&buffer,"LATENCY SCAN",&format!("{} of {} locations replied.",results.iter().filter(|(_,ms)|ms.is_some()).count(),results.len())); }
                }
            }
            glib::ControlFlow::Continue
        });
    }

    {
        let tx=tx.clone(); let user=Rc::clone(&user); let pass=Rc::clone(&pass); let location=Rc::clone(&location); let restricted_mode=Rc::clone(&restricted_mode); let mss=Rc::clone(&mss); let dns=Rc::clone(&dns); let hotspot_vpn=Rc::clone(&hotspot_vpn); let hotspot_iface=Rc::clone(&hotspot_iface); let hotspot_vpn_macs=Rc::clone(&hotspot_vpn_macs); let hotspot_direct_macs=Rc::clone(&hotspot_direct_macs); let recover_network=Rc::clone(&recover_network); let kill_switch=Rc::clone(&kill_switch); let routing_mode=Rc::clone(&routing_mode);
        connect.connect_clicked(move |_| {
            let id=location.active_id().map(|s|s.to_string()).unwrap_or_else(||"ee-tll".to_string()); let Some(selected)=by_id(&id) else{return;};
            let username=user.text().trim().to_string(); let password=pass.text().to_string(); if username.is_empty(){let _=tx.send(Event::Failed("Surfshark service username is required in Settings.".into()));return;}
            let current=AppSettings{restricted:restricted_mode.is_active(),mss:mss.value_as_int().clamp(900,1400) as u32,dns:if dns.text().trim().is_empty(){DEFAULT_DNS.to_string()}else{dns.text().trim().to_string()},hotspot_vpn:hotspot_vpn.is_active(),hotspot_iface:hotspot_iface.active_id().map(|s|s.to_string()).unwrap_or_else(||"auto".into()),recover_network:recover_network.is_active(),kill_switch:kill_switch.is_active(),routing_mode:routing_mode.active_id().map(|s|s.to_string()).unwrap_or_else(||"vpn_all".into()),hotspot_vpn_macs:normalize_mac_csv(hotspot_vpn_macs.text().as_str()),hotspot_direct_macs:normalize_mac_csv(hotspot_direct_macs.text().as_str())};
            save_username(&username); save_settings(&current); let tx=tx.clone();
            thread::spawn(move || { let _=tx.send(Event::Busy(format!("Connecting to {}…",selected.city))); if current.restricted { if nm_active(){let _=nm(&["--wait","5","connection","down",PROFILE]);} let candidates=restricted_candidates(selected.host); let _=tx.send(Event::Log("RESTRICTED ENDPOINTS".into(),format!("{} candidate(s)\nMSS={}\nDNS={}\nRouting={}\nKill switch={}\nHotspot={}\nVPN MACs={}\nDirect MACs={}",candidates.len(),current.mss,current.dns,current.routing_mode,current.kill_switch,current.hotspot_iface,current.hotspot_vpn_macs,current.hotspot_direct_macs))); if candidates.is_empty(){let _=tx.send(Event::Failed("No restricted endpoint exists for this location yet.".into()));return;} for (i,endpoint) in candidates.iter().enumerate(){let _=tx.send(Event::Busy(format!("{} · secure route {}/{}",selected.city,i+1,candidates.len()))); let (ok,log)=restricted_connect(endpoint,&username,&password,&current); let _=tx.send(Event::Log(format!("RESTRICTED ATTEMPT {}/{}",i+1,candidates.len()),log.clone())); if ok {let ip=parse_helper_value(&log,"Public IPv4").unwrap_or_else(||"connected".into()); let country=parse_helper_value(&log,"Exit country").unwrap_or_default(); let hotspot=parse_helper_value(&log,"Device policy").or_else(||parse_helper_value(&log,"Hotspot VPN")).unwrap_or_else(||"default policy".into()); let mode=parse_helper_value(&log,"Routing mode").unwrap_or_else(||current.routing_mode.clone()); let label=if country.is_empty(){format!("{} · {}",selected.label,mode)}else{format!("{} · {} · {}",selected.label,country,mode)}; let _=tx.send(Event::Connected(ip,label,hotspot));return;}} let _=restricted_disconnect(); let _=tx.send(Event::Failed(format!("All {} restricted endpoints failed.",candidates.len())));} else {if restricted_active(){let _=restricted_disconnect();} let pass_opt=if password.is_empty(){None}else{Some(password.as_str())}; let (ok,log)=standard_connect(selected.host,&username,pass_opt); let _=tx.send(Event::Log("NETWORKMANAGER CONNECT".into(),log)); if ok {let _=tx.send(Event::Connected(public_ip().trim().to_string(),selected.label.to_string(),"normal route".into()));} else {let _=tx.send(Event::Failed("NetworkManager IKEv2 activation failed.".into()));}} });
        });
    }
    {
        let tx=tx.clone(); disconnect.connect_clicked(move |_| { let tx=tx.clone(); thread::spawn(move || {let _=tx.send(Event::Busy("Restoring network…".into())); let mut log=String::new(); if restricted_active()||fs::metadata(RESTRICTED_STATE).is_ok(){log.push_str(&restricted_disconnect());log.push('\n');} if nm_active(){log.push_str(&nm(&["--wait","5","connection","down",PROFILE]));} let _=tx.send(Event::Log("DISCONNECT".into(),log)); let _=tx.send(if any_vpn_active(){Event::Failed("VPN still appears active after cleanup.".into())}else{Event::Disconnected});});});
    }
    {
        let tx=tx.clone(); refresh.connect_clicked(move |_| { let tx=tx.clone(); thread::spawn(move || {let _=tx.send(Event::Busy("Refreshing…".into())); let active=any_vpn_active(); let text=format!("restricted_active={}\nnetworkmanager_active={}\nvirtual_ip={}\npublic_ip={}\nrouting_mode={}\nkill_switch={}\nwatchdog={}\nrx={}\ntx={}\nlatency={}\nhotspot_iface={}\nvpn_device_count={}\ndirect_device_count={}",restricted_active(),nm_active(),state_value("VIRTUAL_IP").unwrap_or_else(||"—".into()),state_value("PUBLIC_IP").unwrap_or_else(||if active{public_ip()}else{"—".into()}),state_value("ROUTING_MODE").unwrap_or_else(||"—".into()),state_value("KILL_SWITCH").unwrap_or_else(||"—".into()),live_value("HEALTH").unwrap_or_else(||"—".into()),live_value("RX_BPS").unwrap_or_else(||"0".into()),live_value("TX_BPS").unwrap_or_else(||"0".into()),live_value("LATENCY_MS").unwrap_or_else(||"0".into()),state_value("HOTSPOT_IFACE").unwrap_or_else(||"—".into()),state_value("HOTSPOT_VPN_MAC_COUNT").unwrap_or_else(||"0".into()),state_value("HOTSPOT_DIRECT_MAC_COUNT").unwrap_or_else(||"0".into())); let _=tx.send(Event::Refreshed(active,text));});});
    }
    {
        let tx=tx.clone(); ping_button.connect_clicked(move |_| {let tx=tx.clone();thread::spawn(move || {let _=tx.send(Event::PingStarted);let _=tx.send(Event::PingResults(scan_latencies()));});});
    }

    window.present();
}
