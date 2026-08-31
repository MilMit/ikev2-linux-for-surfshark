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

#[derive(Debug)]
enum Event {
    Busy(String),
    Log(String, String),
    Connected(String, String),
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
            if !out.stdout.is_empty() {
                text.push_str(&String::from_utf8_lossy(&out.stdout));
            }
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

fn restricted_active() -> bool {
    let Ok(state) = fs::read_to_string(RESTRICTED_STATE) else { return false; };
    let vip = state.lines().find_map(|line| line.strip_prefix("VIRTUAL_IP="));
    let Some(vip) = vip else { return false; };
    run("ip", &["-4", "addr", "show"]).contains(vip)
}

fn any_vpn_active() -> bool { restricted_active() || nm_active() }

fn username_path() -> PathBuf {
    let base = std::env::var("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|_| std::env::var("HOME").map(|h| PathBuf::from(h).join(".config")))
        .unwrap_or_else(|_| PathBuf::from("."));
    base.join("milmit-surfshark").join("username")
}

fn saved_username() -> Option<String> {
    fs::read_to_string(username_path()).ok().map(|v| v.trim().to_string()).filter(|v| !v.is_empty())
}

fn save_username(value: &str) {
    let path = username_path();
    if let Some(parent) = path.parent() { let _ = fs::create_dir_all(parent); }
    let _ = fs::write(path, value);
}

fn public_ip() -> String {
    run("curl", &["-4", "--max-time", "8", "-sS", "https://api.ipify.org"])
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
    if let Some(password) = password {
        cmd.args(["vpn.secrets", &format!("password={password}")]);
    }
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
    log.push_str("\n");
    log.push_str(&nm(&["--wait", "15", "connection", "up", PROFILE]));
    (nm_active(), log)
}

fn restricted_candidates(host: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    // Verified from the official Android app's live IKEv2 log on Estonia/Tallinn.
    if host == "ee-tll.prod.surfshark.com" {
        out.push("185.174.159.123".to_string());
    }
    for ip in bundled_for_host(host) {
        if !out.iter().any(|v| v == ip) { out.push((*ip).to_string()); }
    }
    out
}

fn restricted_connect(endpoint: &str, username: &str, password: &str) -> (bool, String) {
    let mut child = match Command::new("pkexec")
        .arg("bash")
        .arg(RESTRICTED_CONNECT)
        .arg(endpoint)
        .arg(username)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(e) => return (false, format!("Could not start restricted helper: {e}")),
    };
    if let Some(stdin) = child.stdin.as_mut() {
        let _ = writeln!(stdin, "{password}");
    }
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

fn restricted_disconnect() -> String {
    run("pkexec", &["bash", RESTRICTED_DISCONNECT])
}

fn parse_helper_value(text: &str, key: &str) -> Option<String> {
    text.lines().find_map(|line| {
        let (k, v) = line.split_once(':')?;
        (k.trim() == key).then(|| v.trim().to_string())
    }).filter(|v| !v.is_empty())
}

fn ping_ms(host: &str) -> Option<u32> {
    let target = if host == "ee-tll.prod.surfshark.com" {
        "185.174.159.123"
    } else {
        bundled_for_host(host).first().copied().unwrap_or(host)
    };
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
        ".hero { padding: 28px; border-radius: 22px; background: linear-gradient(135deg, rgba(65,83,255,.18), rgba(40,190,155,.12)); }\n\
         .hero-title { font-size: 28px; font-weight: 800; }\n\
         .status-pill { padding: 7px 12px; border-radius: 999px; background: alpha(@accent_bg_color, .14); }\n\
         .panel { padding: 14px; border-radius: 14px; }\n\
         .compat-box { padding: 12px; border-radius: 14px; background: alpha(@warning_bg_color, .08); }\n\
         .primary-connect { min-height: 44px; padding-left: 30px; padding-right: 30px; }\n\
         .small-note { font-size: 11px; }\n\
         .diag-box { font-size: 12px; }"
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

    let header = adw::HeaderBar::new();
    header.set_title_widget(Some(&adw::WindowTitle::new("Surfshark IKEv2", "Unofficial Linux client by MilMit")));

    let status = gtk::Label::builder()
        .label(if any_vpn_active() { "🟢 Connected" } else { "Ready" })
        .css_classes(["status-pill"]).build();
    let spinner = gtk::Spinner::new();
    let hero_top = gtk::Box::new(Orientation::Horizontal, 12);
    hero_top.append(&status); hero_top.append(&spinner);
    let hero = gtk::Box::new(Orientation::Vertical, 10);
    hero.add_css_class("hero"); hero.append(&hero_top);
    hero.append(&gtk::Label::builder().label("Private. Fast. Native IKEv2.").halign(gtk::Align::Start).css_classes(["hero-title"]).build());
    hero.append(&gtk::Label::builder().label("Restricted mode uses direct strongSwan, IP-based Surfshark endpoints, Android-matched IKE proposals, DNS repair and MSS=1200 for filtered/mobile networks.").halign(gtk::Align::Start).wrap(true).css_classes(["dim-label"]).build());

    let location = gtk::ComboBoxText::new(); location.set_hexpand(true);
    for item in LOCATIONS { location.append(Some(item.id), item.label); }
    location.set_active_id(Some("ee-tll"));
    let ping_button = gtk::Button::with_label("Test latency");
    let location_row = gtk::Box::new(Orientation::Horizontal, 8); location_row.append(&location); location_row.append(&ping_button);
    let location_box = gtk::Box::new(Orientation::Vertical, 7); location_box.add_css_class("panel");
    location_box.append(&gtk::Label::builder().label("Location").halign(gtk::Align::Start).css_classes(["heading"]).build());
    location_box.append(&location_row);
    location_box.append(&gtk::Label::builder().label("🟢 fast · 🟡 medium · 🟠 slow · ⚪ no ICMP reply").halign(gtk::Align::Start).css_classes(["dim-label", "small-note"]).build());

    let restricted_mode = gtk::CheckButton::with_label("Restricted network / Iran compatibility mode"); restricted_mode.set_active(true);
    let restricted_box = gtk::Box::new(Orientation::Vertical, 5); restricted_box.add_css_class("compat-box"); restricted_box.append(&restricted_mode);
    restricted_box.append(&gtk::Label::builder().label("Direct strongSwan backend: AES-256-GCM/ECP521 → EAP-MSCHAPv2 → ESP AES-256/SHA1 → Surfshark DNS → MSS clamp. Estonia endpoint is verified from the official Android client; other locations rotate bundled candidates until one passes the real data-path test.").halign(gtk::Align::Start).wrap(true).css_classes(["dim-label", "small-note"]).build());

    let user = gtk::Entry::builder().placeholder_text("Surfshark service username").hexpand(true).build();
    if let Some(name) = saved_username() { user.set_text(&name); }
    let pass = gtk::PasswordEntry::builder().placeholder_text("Service password · blank reuses saved restricted credential").show_peek_icon(true).hexpand(true).build();
    let creds_note = gtk::Label::builder().label("Restricted mode saves the Surfshark service secret root-only after the first successful setup.").halign(gtk::Align::Start).wrap(true).css_classes(["dim-label", "small-note"]).build();
    let credentials = gtk::Box::new(Orientation::Vertical, 8); credentials.append(&user); credentials.append(&pass); credentials.append(&creds_note);

    let connect = gtk::Button::with_label("Connect"); connect.add_css_class("suggested-action"); connect.add_css_class("primary-connect");
    let disconnect = gtk::Button::with_label("Disconnect"); disconnect.add_css_class("destructive-action");
    let refresh = gtk::Button::with_label("Refresh status");
    let actions = gtk::Box::new(Orientation::Horizontal, 8); actions.set_halign(gtk::Align::Center); actions.append(&connect); actions.append(&disconnect); actions.append(&refresh);

    let ip_label = gtk::Label::builder().label("Public IP: —").halign(gtk::Align::Center).css_classes(["dim-label"]).build();
    let text_view = gtk::TextView::builder().editable(false).monospace(true).wrap_mode(gtk::WrapMode::WordChar).top_margin(12).bottom_margin(12).left_margin(12).right_margin(12).css_classes(["diag-box"]).build();
    let buffer = text_view.buffer(); buffer.set_text("Surfshark IKEv2 diagnostic log\n");
    let scroller = gtk::ScrolledWindow::builder().vexpand(true).hexpand(true).min_content_height(240).child(&text_view).build();
    let expander = gtk::Expander::new(Some("Advanced diagnostics")); expander.set_child(Some(&scroller));

    let content = gtk::Box::new(Orientation::Vertical, 16); content.set_margin_top(18); content.set_margin_bottom(18); content.set_margin_start(22); content.set_margin_end(22);
    for w in [&hero, &location_box, &restricted_box, &credentials, &actions] { content.append(w); }
    content.append(&ip_label); content.append(&expander);
    let root = gtk::Box::new(Orientation::Vertical, 0); root.append(&header); root.append(&content);
    let window = adw::ApplicationWindow::builder().application(app).title("Surfshark IKEv2 for Linux").default_width(760).default_height(790).content(&root).build();

    let (tx, rx) = mpsc::channel::<Event>();
    let status = Rc::new(status); let spinner = Rc::new(spinner); let connect = Rc::new(connect); let disconnect = Rc::new(disconnect); let refresh = Rc::new(refresh); let ping_button = Rc::new(ping_button); let buffer = Rc::new(buffer); let ip_label = Rc::new(ip_label); let pass = Rc::new(pass); let user = Rc::new(user); let location = Rc::new(location); let restricted_mode = Rc::new(restricted_mode);

    {
        let status = Rc::clone(&status); let spinner = Rc::clone(&spinner); let connect = Rc::clone(&connect); let disconnect = Rc::clone(&disconnect); let refresh = Rc::clone(&refresh); let ping_button = Rc::clone(&ping_button); let buffer = Rc::clone(&buffer); let ip_label = Rc::clone(&ip_label); let pass = Rc::clone(&pass); let location = Rc::clone(&location);
        glib::timeout_add_local(Duration::from_millis(80), move || {
            while let Ok(event) = rx.try_recv() {
                match event {
                    Event::Busy(message) => { status.set_label(&message); spinner.start(); connect.set_sensitive(false); disconnect.set_sensitive(false); refresh.set_sensitive(false); }
                    Event::Log(title, body) => append_log(&buffer, &title, &body),
                    Event::Connected(ip, label) => { spinner.stop(); status.set_label("🟢 Connected"); ip_label.set_label(&format!("{label} · Public IP: {ip}")); connect.set_sensitive(true); disconnect.set_sensitive(true); refresh.set_sensitive(true); pass.set_text(""); }
                    Event::Disconnected => { spinner.stop(); status.set_label("Disconnected"); ip_label.set_label("Public IP: —"); connect.set_sensitive(true); disconnect.set_sensitive(true); refresh.set_sensitive(true); }
                    Event::Failed(message) => { spinner.stop(); status.set_label("Connection failed"); connect.set_sensitive(true); disconnect.set_sensitive(true); refresh.set_sensitive(true); append_log(&buffer, "ERROR", &message); }
                    Event::Refreshed(active, text) => { spinner.stop(); status.set_label(if active { "🟢 Connected" } else { "Disconnected" }); connect.set_sensitive(true); disconnect.set_sensitive(true); refresh.set_sensitive(true); append_log(&buffer, "STATUS", &text); }
                    Event::PingStarted => { ping_button.set_sensitive(false); ping_button.set_label("Testing…"); }
                    Event::PingResults(results) => { ping_button.set_sensitive(true); ping_button.set_label("Test latency"); repopulate_locations(&location, &results); append_log(&buffer, "LATENCY SCAN", &format!("{} of {} locations replied.", results.iter().filter(|(_, ms)| ms.is_some()).count(), results.len())); }
                }
            }
            glib::ControlFlow::Continue
        });
    }

    {
        let tx = tx.clone(); let user = Rc::clone(&user); let pass = Rc::clone(&pass); let location = Rc::clone(&location); let restricted_mode = Rc::clone(&restricted_mode);
        connect.connect_clicked(move |_| {
            let id = location.active_id().map(|s| s.to_string()).unwrap_or_else(|| "ee-tll".to_string());
            let Some(selected) = by_id(&id) else { return; };
            let username = user.text().trim().to_string(); let password = pass.text().to_string(); let restricted = restricted_mode.is_active(); let tx = tx.clone();
            if username.is_empty() { let _ = tx.send(Event::Failed("Surfshark service username is required.".into())); return; }
            save_username(&username);
            thread::spawn(move || {
                let _ = tx.send(Event::Busy(format!("Connecting to {}…", selected.city)));
                if restricted {
                    if nm_active() { let _ = nm(&["--wait", "5", "connection", "down", PROFILE]); }
                    let candidates = restricted_candidates(selected.host);
                    let _ = tx.send(Event::Log("RESTRICTED ENDPOINTS".into(), format!("{} candidate(s):\n{}", candidates.len(), candidates.join("\n"))));
                    if candidates.is_empty() { let _ = tx.send(Event::Failed("No bundled restricted endpoint exists for this location yet.".into())); return; }
                    for (i, endpoint) in candidates.iter().enumerate() {
                        let _ = tx.send(Event::Busy(format!("{} · endpoint {}/{}…", selected.city, i + 1, candidates.len())));
                        let (ok, log) = restricted_connect(endpoint, &username, &password);
                        let _ = tx.send(Event::Log(format!("RESTRICTED ATTEMPT {}/{}", i + 1, candidates.len()), log.clone()));
                        if ok {
                            let ip = parse_helper_value(&log, "Public IPv4").unwrap_or_else(|| "connected".into());
                            let country = parse_helper_value(&log, "Exit country").unwrap_or_default();
                            let label = if country.is_empty() { selected.label.to_string() } else { format!("{} · {}", selected.label, country) };
                            let _ = tx.send(Event::Connected(ip, label)); return;
                        }
                    }
                    let _ = tx.send(Event::Failed(format!("All {} restricted endpoint candidate(s) failed.", candidates.len())));
                } else {
                    if restricted_active() { let _ = restricted_disconnect(); }
                    let pass_opt = if password.is_empty() { None } else { Some(password.as_str()) };
                    let (ok, log) = standard_connect(selected.host, &username, pass_opt);
                    let _ = tx.send(Event::Log("NETWORKMANAGER CONNECT".into(), log));
                    if ok { let _ = tx.send(Event::Connected(public_ip().trim().to_string(), selected.label.to_string())); }
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
                let _ = tx.send(Event::Busy("Disconnecting…".into()));
                let mut log = String::new();
                if restricted_active() { log.push_str(&restricted_disconnect()); log.push('\n'); }
                if nm_active() { log.push_str(&nm(&["--wait", "5", "connection", "down", PROFILE])); }
                let _ = tx.send(Event::Log("DISCONNECT".into(), log));
                let _ = tx.send(if any_vpn_active() { Event::Failed("VPN still appears active.".into()) } else { Event::Disconnected });
            });
        });
    }

    {
        let tx = tx.clone();
        refresh.connect_clicked(move |_| {
            let tx = tx.clone();
            thread::spawn(move || {
                let _ = tx.send(Event::Busy("Refreshing…".into()));
                let active = any_vpn_active();
                let text = format!("restricted_active={}\nnetworkmanager_active={}\npublic_ip={}", restricted_active(), nm_active(), if active { public_ip() } else { "—".into() });
                let _ = tx.send(Event::Refreshed(active, text));
            });
        });
    }

    {
        let tx = tx.clone(); ping_button.connect_clicked(move |_| { let tx = tx.clone(); thread::spawn(move || { let _ = tx.send(Event::PingStarted); let _ = tx.send(Event::PingResults(scan_latencies())); }); });
    }

    window.present();
}
