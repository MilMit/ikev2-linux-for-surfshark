mod bundled_endpoints;
mod location_browser;
mod locations;

use adw::prelude::*;
use bundled_endpoints::for_host as bundled_for_host;
use gtk::{glib, Orientation};
use locations::by_id;
use std::cell::RefCell;
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::rc::Rc;
use std::thread;
use std::time::Duration;

const HELPER: &str = "/usr/libexec/milmit-surfshark-helper";
const STATE: &str = "/run/milmit-surfshark/restricted.state";
const LIVE: &str = "/run/milmit-surfshark/live.state";
const DEFAULT_DNS: &str = "162.252.172.57,149.154.159.92";

#[derive(Clone)]
struct Settings {
    mss: u32,
    dns: String,
    hotspot_vpn: bool,
    hotspot_iface: String,
    recover: bool,
    kill: bool,
    routing: String,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            mss: 1200,
            dns: DEFAULT_DNS.into(),
            hotspot_vpn: true,
            hotspot_iface: "auto".into(),
            recover: true,
            kill: true,
            routing: "vpn_all".into(),
        }
    }
}

fn cfg_dir() -> PathBuf {
    std::env::var("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|_| std::env::var("HOME").map(|h| PathBuf::from(h).join(".config")))
        .unwrap_or_else(|_| PathBuf::from("."))
        .join("milmit-surfshark")
}
fn cfg_path() -> PathBuf {
    cfg_dir().join("settings.conf")
}
fn user_path() -> PathBuf {
    cfg_dir().join("username")
}
fn saved_user() -> String {
    fs::read_to_string(user_path())
        .unwrap_or_default()
        .trim()
        .to_string()
}
fn save_user(v: &str) {
    let p = user_path();
    if let Some(d) = p.parent() {
        let _ = fs::create_dir_all(d);
    }
    let _ = fs::write(p, v);
}
fn load_settings() -> Settings {
    let mut s = Settings::default();
    if let Ok(t) = fs::read_to_string(cfg_path()) {
        for l in t.lines() {
            if let Some((k, v)) = l.split_once('=') {
                match k {
                    "mss" => {
                        if let Ok(n) = v.parse() {
                            s.mss = n
                        }
                    }
                    "dns" => s.dns = v.into(),
                    "hotspot_vpn" => s.hotspot_vpn = v == "1",
                    "hotspot_iface" => s.hotspot_iface = v.into(),
                    "recover" => s.recover = v == "1",
                    "kill" => s.kill = v == "1",
                    "routing" => s.routing = v.into(),
                    _ => {}
                }
            }
        }
    }
    s
}
fn save_settings(s: &Settings) {
    let p = cfg_path();
    if let Some(d) = p.parent() {
        let _ = fs::create_dir_all(d);
    }
    let _ =
        fs::write(
            p,
            format!(
        "mss={}\ndns={}\nhotspot_vpn={}\nhotspot_iface={}\nrecover={}\nkill={}\nrouting={}\n",
        s.mss, s.dns, s.hotspot_vpn as u8, s.hotspot_iface, s.recover as u8, s.kill as u8, s.routing
    ),
        );
}
fn value(path: &str, key: &str) -> Option<String> {
    let t = fs::read_to_string(path).ok()?;
    t.lines().find_map(|l| {
        let (k, v) = l.split_once('=')?;
        (k == key).then(|| v.trim().to_string())
    })
}
fn active() -> bool {
    value(STATE, "VIRTUAL_IP")
        .map(|v| {
            Command::new("ip")
                .args(["-4", "addr", "show"])
                .output()
                .ok()
                .map(|o| String::from_utf8_lossy(&o.stdout).contains(&v))
                .unwrap_or(false)
        })
        .unwrap_or(false)
}
fn helper(args: &[&str]) -> String {
    match Command::new("pkexec").arg(HELPER).args(args).output() {
        Ok(o) => {
            let mut t = String::from_utf8_lossy(&o.stdout).to_string();
            t.push_str(&String::from_utf8_lossy(&o.stderr));
            t
        }
        Err(e) => e.to_string(),
    }
}
fn helper_stdin(args: &[&str], input: &str) -> (bool, String) {
    let mut c = match Command::new("pkexec")
        .arg(HELPER)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => return (false, e.to_string()),
    };
    if let Some(stdin) = c.stdin.as_mut() {
        let _ = writeln!(stdin, "{input}");
    }
    match c.wait_with_output() {
        Ok(o) => {
            let text = format!(
                "{}{}",
                String::from_utf8_lossy(&o.stdout),
                String::from_utf8_lossy(&o.stderr)
            );
            (o.status.success(), text)
        }
        Err(e) => (false, e.to_string()),
    }
}
fn candidate_ips(host: &str) -> Vec<String> {
    let mut v = Vec::new();
    if host == "ee-tll.prod.surfshark.com" {
        v.push("185.174.159.123".into());
    }
    for x in bundled_for_host(host) {
        if !v.iter().any(|e| e == x) {
            v.push((*x).into());
        }
    }
    v
}
fn connect_vpn(host: &str, user: &str, s: &Settings) -> (bool, String) {
    let mut log = String::new();
    for ip in candidate_ips(host) {
        let m = s.mss.to_string();
        let hotspot = if s.hotspot_vpn { "1" } else { "0" };
        let recover = if s.recover { "1" } else { "0" };
        let kill = if s.kill { "1" } else { "0" };
        let (ok, t) = helper_stdin(
            &[
                "connect",
                &ip,
                user,
                &m,
                &s.dns,
                hotspot,
                recover,
                &s.hotspot_iface,
                kill,
                &s.routing,
                "",
                "",
                host,
            ],
            "",
        );
        log.push_str(&format!("\n[{ip}]\n{t}\n"));
        if ok && t.contains("Data-path test: OK") {
            return (true, log);
        }
    }
    (false, log)
}
fn ping_report(target: &str) -> String {
    match Command::new("ping")
        .args(["-n", "-c", "8", "-W", "2", target])
        .output()
    {
        Ok(o) => {
            let mut raw = String::from_utf8_lossy(&o.stdout).to_string();
            if !o.stderr.is_empty() {
                raw.push_str(&String::from_utf8_lossy(&o.stderr));
            }
            let loss = raw
                .lines()
                .find(|l| l.contains("packet loss"))
                .unwrap_or("Packet loss: unavailable");
            let stats = raw
                .lines()
                .find(|l| l.contains("min/avg/max") || l.contains("round-trip"))
                .unwrap_or("RTT/jitter: unavailable");
            format!("Target: {target}\n{loss}\n{stats}\n\n{raw}")
        }
        Err(e) => format!("Ping failed for {target}: {e}"),
    }
}

fn css() {
    let p = gtk::CssProvider::new();
    p.load_from_data(r#"
window{background:#192e45;color:#fff}.root{background:#192e45}.top{background:#17314d;padding:10px 14px;border-bottom:1px solid rgba(255,255,255,.06)}
.brand{font-size:18px;font-weight:900}.caption{font-size:11px;color:#a8bacb}.page{padding:20px}.hero{padding:26px 20px;background:#213d59;border-radius:18px}
.hero-title{font-size:28px;font-weight:900}.hero-sub{font-size:13px;color:#b9c9d7}.shield{min-width:118px;min-height:118px;border-radius:999px;background:#294d6d;border:3px solid #4f7698}
.shield-on{background:#1f694f;border-color:#5bd39a}.shield-busy{background:#7a5c20;border-color:#e8bd57}.big-icon{-gtk-icon-size:52px}.primary{min-height:50px;border-radius:10px;background:#57c28b;color:#082317;font-weight:900}
.primary:hover{background:#68d69c}.danger{min-height:50px;border-radius:10px;background:#c94d5b;color:#fff;font-weight:900}.location{min-height:64px;border-radius:12px;background:#27435f;border:1px solid rgba(255,255,255,.06);padding:0 14px}
.location:hover{background:#2d4b68}.row{min-height:54px;background:#223d58;border-bottom:1px solid rgba(255,255,255,.06);padding:0 14px}.row-title{font-size:14px;font-weight:700}.row-sub{font-size:11px;color:#a9bac9}
.section{font-size:12px;font-weight:800;color:#a9bac9;margin-top:8px}.back{background:transparent;box-shadow:none}.pill{background:#2b4b68;border-radius:999px;padding:6px 10px;font-size:11px}.diag{background:#11273b;border-radius:12px;padding:12px;font-family:monospace;font-size:11px}
entry,spinbutton,combobox button{min-height:42px;border-radius:9px;background:#203a54}switch{margin:6px}.stack{background:#192e45}
.location-list{background:transparent}.country-expander{background:#223d58;border-radius:12px;padding:4px 8px;margin-bottom:6px}.location-city-row{min-height:52px;padding:3px 4px;background:#203a54;border-radius:9px;margin:2px 0}
.flat-location{background:transparent;box-shadow:none;padding:3px 8px}.ping-badge{background:#163048;border-radius:999px;padding:5px 8px;font-size:11px;font-weight:800}.star-button{background:transparent;box-shadow:none;font-size:18px;min-width:34px}
.context-button{background:transparent;box-shadow:none;min-height:36px;text-align:left}.notice{margin:8px 12px 0}.busy-spinner{margin-top:4px}
"#);
    if let Some(d) = gtk::gdk::Display::default() {
        gtk::style_context_add_provider_for_display(
            &d,
            &p,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        )
    }
}
fn title_box(t: &str, s: &str) -> gtk::Box {
    let b = gtk::Box::new(Orientation::Vertical, 2);
    b.append(
        &gtk::Label::builder()
            .label(t)
            .halign(gtk::Align::Start)
            .css_classes(["row-title"])
            .build(),
    );
    if !s.is_empty() {
        b.append(
            &gtk::Label::builder()
                .label(s)
                .halign(gtk::Align::Start)
                .wrap(true)
                .css_classes(["row-sub"])
                .build(),
        );
    }
    b
}
fn page_header(stack: &gtk::Stack, title: &str) -> gtk::Box {
    let b = gtk::Box::new(Orientation::Horizontal, 8);
    b.add_css_class("top");
    let back = gtk::Button::from_icon_name("go-previous-symbolic");
    back.add_css_class("back");
    let st = stack.clone();
    back.connect_clicked(move |_| st.set_visible_child_name("settings"));
    b.append(&back);
    b.append(
        &gtk::Label::builder()
            .label(title)
            .hexpand(true)
            .halign(gtk::Align::Start)
            .css_classes(["brand"])
            .build(),
    );
    b
}
fn nav_row(title: &str, sub: &str) -> (gtk::Button, gtk::Box) {
    let button = gtk::Button::new();
    button.add_css_class("row");
    button.set_hexpand(true);
    let row = gtk::Box::new(Orientation::Horizontal, 10);
    row.append(&title_box(title, sub));
    let spacer = gtk::Box::new(Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    row.append(&spacer);
    row.append(&gtk::Image::from_icon_name("go-next-symbolic"));
    button.set_child(Some(&row));
    let wrap = gtk::Box::new(Orientation::Vertical, 0);
    wrap.append(&button);
    (button, wrap)
}
fn switch_row(title: &str, sub: &str, on: bool) -> (gtk::Box, gtk::Switch) {
    let row = gtk::Box::new(Orientation::Horizontal, 10);
    row.add_css_class("row");
    row.append(&title_box(title, sub));
    let spacer = gtk::Box::new(Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    row.append(&spacer);
    let sw = gtk::Switch::builder()
        .active(on)
        .valign(gtk::Align::Center)
        .build();
    row.append(&sw);
    (row, sw)
}
fn notice(banner: &adw::Banner, text: &str) {
    banner.set_title(text);
    banner.set_revealed(true);
}

fn main() -> glib::ExitCode {
    let app = adw::Application::builder()
        .application_id("net.milmit.SurfsharkIkev2")
        .build();
    app.connect_activate(build);
    app.run()
}

fn build(app: &adw::Application) {
    css();
    let settings = Rc::new(RefCell::new(load_settings()));
    let selected = Rc::new(RefCell::new("ee-tll".to_string()));
    let stack = gtk::Stack::new();
    stack.add_css_class("stack");
    stack.set_transition_type(gtk::StackTransitionType::SlideLeftRight);
    stack.set_transition_duration(240);

    let root = gtk::Box::new(Orientation::Vertical, 0);
    root.add_css_class("root");
    let top = gtk::Box::new(Orientation::Horizontal, 10);
    top.add_css_class("top");
    top.append(
        &gtk::Label::builder()
            .label("MilMit Secure")
            .halign(gtk::Align::Start)
            .css_classes(["brand"])
            .build(),
    );
    let spacer = gtk::Box::new(Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    top.append(&spacer);
    let settings_btn = gtk::Button::from_icon_name("emblem-system-symbolic");
    settings_btn.add_css_class("back");
    top.append(&settings_btn);
    root.append(&top);
    let banner = adw::Banner::builder().title("").build();
    banner.add_css_class("notice");
    banner.set_revealed(false);
    root.append(&banner);

    // Home / connection state.
    let home = gtk::Box::new(Orientation::Vertical, 16);
    home.add_css_class("page");
    let on = active();
    let shield = gtk::Box::new(Orientation::Vertical, 0);
    shield.add_css_class("shield");
    if on {
        shield.add_css_class("shield-on");
    }
    shield.set_halign(gtk::Align::Center);
    shield.set_valign(gtk::Align::Center);
    let icon = gtk::Image::from_icon_name(if on {
        "network-vpn-symbolic"
    } else {
        "network-offline-symbolic"
    });
    icon.add_css_class("big-icon");
    shield.append(&icon);
    let spinner = gtk::Spinner::new();
    spinner.add_css_class("busy-spinner");
    spinner.set_visible(false);
    shield.append(&spinner);
    let status = gtk::Label::builder()
        .label(if on {
            "SECURE CONNECTION"
        } else {
            "UNSECURED CONNECTION"
        })
        .css_classes(["hero-title"])
        .build();
    let status_sub = gtk::Label::builder()
        .label(if on {
            "Your traffic is protected"
        } else {
            "Connect to protect your traffic"
        })
        .css_classes(["hero-sub"])
        .build();
    let hero = gtk::Box::new(Orientation::Vertical, 10);
    hero.add_css_class("hero");
    hero.append(&shield);
    hero.append(&status);
    hero.append(&status_sub);
    home.append(&hero);

    let loc_btn = gtk::Button::new();
    loc_btn.add_css_class("location");
    let locrow = gtk::Box::new(Orientation::Horizontal, 10);
    let loclabel = gtk::Label::builder()
        .label("Estonia · Tallinn")
        .hexpand(true)
        .halign(gtk::Align::Start)
        .css_classes(["row-title"])
        .build();
    locrow.append(&gtk::Image::from_icon_name("find-location-symbolic"));
    locrow.append(&loclabel);
    locrow.append(&gtk::Image::from_icon_name("go-next-symbolic"));
    loc_btn.set_child(Some(&locrow));
    home.append(&loc_btn);
    let connect = gtk::Button::with_label(if on {
        "Disconnect"
    } else {
        "Secure my connection"
    });
    connect.add_css_class(if on { "danger" } else { "primary" });
    home.append(&connect);

    let ip_metric = gtk::Label::builder()
        .label(value(STATE, "PUBLIC_IP").unwrap_or_else(|| "—".into()))
        .css_classes(["row-title"])
        .build();
    let exit_metric = gtk::Label::builder()
        .label(value(STATE, "EXIT_COUNTRY").unwrap_or_else(|| "—".into()))
        .css_classes(["row-title"])
        .build();
    let ping_metric = gtk::Label::builder()
        .label(
            value(LIVE, "LATENCY_MS")
                .map(|x| format!("{x} ms"))
                .unwrap_or_else(|| "—".into()),
        )
        .css_classes(["row-title"])
        .build();
    let metrics = gtk::Box::new(Orientation::Horizontal, 8);
    for (k, v) in [
        ("IP", ip_metric.clone()),
        ("EXIT", exit_metric.clone()),
        ("PING", ping_metric.clone()),
    ] {
        let c = gtk::Box::new(Orientation::Vertical, 2);
        c.set_hexpand(true);
        c.add_css_class("pill");
        c.append(&v);
        c.append(
            &gtk::Label::builder()
                .label(k)
                .css_classes(["row-sub"])
                .build(),
        );
        metrics.append(&c);
    }
    home.append(&metrics);
    stack.add_named(&home, Some("home"));

    let locations_page = location_browser::build(&stack, selected.clone(), &loclabel);
    stack.add_named(&locations_page, Some("locations"));

    // Main settings hierarchy.
    let settings_page = gtk::Box::new(Orientation::Vertical, 0);
    settings_page.append(
        &gtk::Label::builder()
            .label("Settings")
            .halign(gtk::Align::Start)
            .css_classes(["brand"])
            .margin_top(14)
            .margin_start(20)
            .build(),
    );
    let sb = gtk::Box::new(Orientation::Vertical, 12);
    sb.add_css_class("page");
    let (credrow, credwrap) = nav_row("Credentials", "Surfshark service username and password");
    sb.append(&credwrap);
    let (vpnrow, vpnwrap) = nav_row(
        "VPN settings",
        "Kill switch, Iran bypass, DNS and transport",
    );
    sb.append(&vpnwrap);
    let (splitrow, splitwrap) = nav_row(
        "Split tunneling",
        "Iran bypass plus Direct / VPN / Block policies",
    );
    sb.append(&splitwrap);
    let (devrow, devwrap) = nav_row(
        "Hotspot & devices",
        "Per-device routes, quota, shaping and guest hotspot",
    );
    sb.append(&devwrap);
    let (toolsrow, toolswrap) = nav_row(
        "Advanced tools",
        "Health, safe apply, route explain and recovery",
    );
    sb.append(&toolswrap);
    let (diagrow, diagwrap) = nav_row("Diagnostics", "Ping, live backend output and support tools");
    sb.append(&diagwrap);
    let back_home = gtk::Button::with_label("Back to connection");
    back_home.add_css_class("location");
    sb.append(&back_home);
    settings_page.append(&sb);
    stack.add_named(&settings_page, Some("settings"));

    // Credentials.
    let cred_page = gtk::Box::new(Orientation::Vertical, 0);
    cred_page.append(&page_header(&stack, "Credentials"));
    let cb = gtk::Box::new(Orientation::Vertical, 10);
    cb.add_css_class("page");
    let username = gtk::Entry::builder()
        .text(&saved_user())
        .placeholder_text("Surfshark service username")
        .build();
    let password = gtk::PasswordEntry::builder()
        .placeholder_text("Service password · leave blank to keep saved password")
        .show_peek_icon(true)
        .build();
    cb.append(&title_box(
        "Surfshark service credentials",
        "Stored by the privileged helper in a root-only file.",
    ));
    cb.append(&username);
    cb.append(&password);
    let savecred = gtk::Button::with_label("Save credentials securely");
    savecred.add_css_class("primary");
    cb.append(&savecred);
    cred_page.append(&cb);
    stack.add_named(&cred_page, Some("credentials"));

    // VPN settings.
    let vpn_page = gtk::Box::new(Orientation::Vertical, 0);
    vpn_page.append(&page_header(&stack, "VPN settings"));
    let vb = gtk::Box::new(Orientation::Vertical, 10);
    vb.add_css_class("page");
    let (krow, ksw) = switch_row(
        "Kill switch",
        "Block unprotected traffic if the VPN path fails",
        settings.borrow().kill,
    );
    vb.append(&krow);
    let (rrow, rsw) = switch_row(
        "Bypass Iranian destinations",
        "Iranian ranges go direct; foreign traffic stays on VPN",
        settings.borrow().routing == "iran_direct",
    );
    vb.append(&rrow);
    let (recrow, recsw) = switch_row(
        "Auto recovery",
        "Watchdog repairs the tunnel automatically",
        settings.borrow().recover,
    );
    vb.append(&recrow);
    let dns = gtk::Entry::builder()
        .text(&settings.borrow().dns)
        .placeholder_text("VPN DNS servers")
        .build();
    vb.append(&title_box("DNS servers", "Comma-separated IPv4 addresses"));
    vb.append(&dns);
    let mss = gtk::SpinButton::with_range(900.0, 1400.0, 10.0);
    mss.set_value(settings.borrow().mss as f64);
    vb.append(&title_box("TCP MSS", "Restricted-network packet clamp"));
    vb.append(&mss);
    let savevpn = gtk::Button::with_label("Save VPN settings");
    savevpn.add_css_class("primary");
    vb.append(&savevpn);
    let update_rules = gtk::Button::with_label("Update Iran rules now");
    update_rules.add_css_class("location");
    vb.append(&update_rules);
    vpn_page.append(&vb);
    stack.add_named(&vpn_page, Some("vpn"));

    // Split tunneling.
    let split_page = gtk::Box::new(Orientation::Vertical, 0);
    split_page.append(&page_header(&stack, "Split tunneling"));
    let spb = gtk::Box::new(Orientation::Vertical, 10);
    spb.add_css_class("page");
    spb.append(&title_box(
        "Iran bypass",
        "Policy priority: Block > Force VPN > Manual Direct > Iran Direct > Default.",
    ));
    let explain = gtk::Entry::builder()
        .placeholder_text("Domain or IP to explain, e.g. digikala.com")
        .build();
    spb.append(&explain);
    let explain_btn = gtk::Button::with_label("Explain route");
    explain_btn.add_css_class("location");
    spb.append(&explain_btn);
    let target = gtk::Entry::builder()
        .placeholder_text("Domain / IP / CIDR")
        .build();
    spb.append(&target);
    let acts = gtk::Box::new(Orientation::Horizontal, 6);
    for (a, label) in [
        ("direct", "Bypass VPN"),
        ("vpn", "Force VPN"),
        ("block", "Block"),
    ] {
        let b = gtk::Button::with_label(label);
        b.set_hexpand(true);
        let t = target.clone();
        let bn = banner.clone();
        b.connect_clicked(move |_| {
            let v = t.text().to_string();
            if !v.is_empty() {
                let out = helper(&["policy-add", &v, a, "both"]);
                notice(
                    &bn,
                    if out.to_lowercase().contains("error") {
                        "Policy action failed"
                    } else {
                        "Policy updated"
                    },
                );
            }
        });
        acts.append(&b);
    }
    spb.append(&acts);
    let cand = gtk::Button::with_label("Recent destinations / candidates");
    cand.add_css_class("location");
    spb.append(&cand);
    split_page.append(&spb);
    stack.add_named(&split_page, Some("split"));

    // Devices / hotspot.
    let dev_page = gtk::Box::new(Orientation::Vertical, 0);
    dev_page.append(&page_header(&stack, "Hotspot & devices"));
    let db = gtk::Box::new(Orientation::Vertical, 10);
    db.add_css_class("page");
    db.append(&title_box(
        "Hotspot routing",
        "Share the protected tunnel with phones and manage per-device policies.",
    ));
    let repair = gtk::Button::with_label("Repair hotspot routing");
    repair.add_css_class("primary");
    db.append(&repair);
    let manager = gtk::Button::with_label("Open visual device manager");
    manager.add_css_class("location");
    db.append(&manager);
    let guest = gtk::Button::with_label("Start 60-minute Guest Hotspot");
    guest.add_css_class("location");
    db.append(&guest);
    let force_dns = gtk::CheckButton::with_label("Force VPN DNS for hotspot clients");
    force_dns.set_active(true);
    let quic = gtk::CheckButton::with_label("Block QUIC (UDP/443)");
    let isolation = gtk::CheckButton::with_label("Client isolation");
    let ipv6 = gtk::CheckButton::with_label("Block hotspot IPv6 leaks");
    ipv6.set_active(true);
    db.append(&force_dns);
    db.append(&quic);
    db.append(&isolation);
    db.append(&ipv6);
    let applydev = gtk::Button::with_label("Apply hotspot protection");
    applydev.add_css_class("primary");
    db.append(&applydev);
    dev_page.append(&db);
    stack.add_named(&dev_page, Some("devices"));

    // Advanced tools.
    let tools_page = gtk::Box::new(Orientation::Vertical, 0);
    tools_page.append(&page_header(&stack, "Advanced tools"));
    let tb = gtk::Box::new(Orientation::Vertical, 8);
    tb.add_css_class("page");
    for (cmd, label) in [
        ("health", "Protection health"),
        ("apply-safe", "Apply safely + rollback"),
        ("full-live-test", "Full live test"),
        ("speed-test", "Speed & TTFB"),
        ("dns-test", "DNS evidence"),
        ("mtu-test", "MTU / MSS probe"),
        ("save-lkg", "Save Last Known Good"),
        ("rules-status", "Iran rules status"),
        ("support-bundle", "Create support bundle"),
    ] {
        let b = gtk::Button::with_label(label);
        b.add_css_class("location");
        let bn = banner.clone();
        b.connect_clicked(move |_| {
            let out = helper(&[cmd]);
            notice(
                &bn,
                if out.to_lowercase().contains("error") || out.contains("\"ok\": false") {
                    "Tool reported a problem — see Diagnostics"
                } else {
                    "Tool completed"
                },
            );
        });
        tb.append(&b);
    }
    let emergency = gtk::Button::with_label("Emergency stop & network recovery");
    emergency.add_css_class("danger");
    let bn = banner.clone();
    emergency.connect_clicked(move |_| {
        let _ = helper(&["emergency-stop"]);
        notice(&bn, "Emergency stop executed");
    });
    tb.append(&emergency);
    tools_page.append(
        &gtk::ScrolledWindow::builder()
            .child(&tb)
            .vexpand(true)
            .build(),
    );
    stack.add_named(&tools_page, Some("tools"));

    // Diagnostics with explicit ping tools.
    let diag_page = gtk::Box::new(Orientation::Vertical, 0);
    diag_page.append(&page_header(&stack, "Diagnostics"));
    let dig = gtk::Box::new(Orientation::Vertical, 10);
    dig.add_css_class("page");
    let ping_actions = gtk::Box::new(Orientation::Horizontal, 6);
    let ping_net = gtk::Button::with_label("Ping Internet");
    let ping_vpn = gtk::Button::with_label("Ping VPN");
    let ping_loc = gtk::Button::with_label("Ping location");
    for b in [&ping_net, &ping_vpn, &ping_loc] {
        b.set_hexpand(true);
        b.add_css_class("location");
        ping_actions.append(b);
    }
    dig.append(&ping_actions);
    let text = gtk::TextView::builder()
        .editable(false)
        .monospace(true)
        .wrap_mode(gtk::WrapMode::WordChar)
        .css_classes(["diag"])
        .vexpand(true)
        .build();
    let buf = text.buffer();
    buf.set_text("MilMit Secure diagnostics\n");
    let refresh = gtk::Button::with_label("Refresh diagnostics");
    refresh.add_css_class("location");
    let b2 = buf.clone();
    refresh.connect_clicked(move |_| {
        let mut out = String::new();
        out.push_str(&helper(&["watchdog-status"]));
        out.push_str("\n\n--- Router ---\n");
        out.push_str(&helper(&["router-status"]));
        out.push_str("\n\n--- Live test ---\n");
        out.push_str(&helper(&["full-live-test"]));
        b2.set_text(&out);
    });
    let bnet = buf.clone();
    ping_net.connect_clicked(move |_| {
        bnet.set_text(&ping_report("1.1.1.1"));
    });
    let bvpn = buf.clone();
    ping_vpn.connect_clicked(move |_| {
        let target = value(STATE, "SERVER_IP").unwrap_or_else(|| "185.174.159.123".into());
        bvpn.set_text(&ping_report(&target));
    });
    let bloc = buf.clone();
    let sel_ping = selected.clone();
    ping_loc.connect_clicked(move |_| {
        let id = sel_ping.borrow().clone();
        if let Some(loc) = by_id(&id) {
            let target = candidate_ips(loc.host)
                .first()
                .cloned()
                .unwrap_or_else(|| loc.host.to_string());
            bloc.set_text(&ping_report(&target));
        }
    });
    dig.append(&refresh);
    dig.append(
        &gtk::ScrolledWindow::builder()
            .child(&text)
            .vexpand(true)
            .build(),
    );
    diag_page.append(&dig);
    stack.add_named(&diag_page, Some("diagnostics"));

    // Navigation.
    {
        let st = stack.clone();
        settings_btn.connect_clicked(move |_| st.set_visible_child_name("settings"));
    }
    {
        let st = stack.clone();
        loc_btn.connect_clicked(move |_| st.set_visible_child_name("locations"));
    }
    {
        let st = stack.clone();
        back_home.connect_clicked(move |_| st.set_visible_child_name("home"));
    }
    for (btn, name) in [
        (credrow, "credentials"),
        (vpnrow, "vpn"),
        (splitrow, "split"),
        (devrow, "devices"),
        (toolsrow, "tools"),
        (diagrow, "diagnostics"),
    ] {
        let st = stack.clone();
        btn.connect_clicked(move |_| st.set_visible_child_name(name));
    }

    // Settings actions and banners.
    {
        let s = settings.clone();
        let bn = banner.clone();
        savevpn.connect_clicked(move |_| {
            let mut v = s.borrow_mut();
            v.kill = ksw.is_active();
            v.recover = recsw.is_active();
            v.routing = if rsw.is_active() {
                "iran_direct".into()
            } else {
                "vpn_all".into()
            };
            v.dns = dns.text().to_string();
            v.mss = mss.value() as u32;
            save_settings(&v);
            notice(&bn, "VPN settings saved");
        });
    }
    {
        let bn = banner.clone();
        update_rules.connect_clicked(move |_| {
            let out = helper(&["rules-update"]);
            notice(
                &bn,
                if out.contains("\"ok\": true") {
                    "Iran rules updated"
                } else {
                    "Iran rules update finished — review Diagnostics if needed"
                },
            );
        });
    }
    {
        let bn = banner.clone();
        explain_btn.connect_clicked(move |_| {
            let v = explain.text().to_string();
            if !v.is_empty() {
                let out = helper(&["route-explain", &v]);
                notice(
                    &bn,
                    if out.is_empty() {
                        "No route explanation returned"
                    } else {
                        "Route explanation generated — see Diagnostics tools for detailed output"
                    },
                );
            }
        });
    }
    cand.connect_clicked(|_| {
        let _ = helper(&["candidates"]);
    });
    {
        let bn = banner.clone();
        repair.connect_clicked(move |_| {
            let out = helper(&["hotspot-repair"]);
            notice(
                &bn,
                if out.contains("\"ok\": true") {
                    "Hotspot routing repaired"
                } else {
                    "Hotspot repair needs attention"
                },
            );
        });
    }
    manager.connect_clicked(|_| {
        let _ = Command::new("pkexec")
            .args([HELPER, "router-status"])
            .spawn();
    });
    {
        let bn = banner.clone();
        guest.connect_clicked(move |_| {
            let out = helper(&["guest-start", "60", "MilMit Guest"]);
            notice(
                &bn,
                if out.contains("\"ok\": true") {
                    "Guest Hotspot started"
                } else {
                    "Could not start Guest Hotspot"
                },
            );
        });
    }
    {
        let bn = banner.clone();
        applydev.connect_clicked(move |_| {
            let out = helper(&[
                "router-options",
                if force_dns.is_active() { "1" } else { "0" },
                if quic.is_active() { "1" } else { "0" },
                if isolation.is_active() { "1" } else { "0" },
                if ipv6.is_active() { "block" } else { "allow" },
            ]);
            notice(
                &bn,
                if out.contains("\"ok\": true") {
                    "Hotspot protection applied"
                } else {
                    "Hotspot options saved"
                },
            );
        });
    }
    {
        let bn = banner.clone();
        savecred.connect_clicked(move |_| {
            let u = username.text().to_string();
            if u.is_empty() {
                notice(&bn, "Enter the Surfshark service username");
                return;
            }
            save_user(&u);
            let p = password.text().to_string();
            if p.is_empty() {
                notice(&bn, "Username saved; existing root-only password kept");
                return;
            }
            let (ok, _) = helper_stdin(&["credentials-save", &u], &p);
            notice(
                &bn,
                if ok {
                    "Credentials saved securely"
                } else {
                    "Credential save failed"
                },
            );
            password.set_text("");
        });
    }

    // Connect/disconnect with animated state and verified teardown feedback.
    let settings_conn = settings.clone();
    let sel_conn = selected.clone();
    let status_c = status.clone();
    let sub_c = status_sub.clone();
    let shield_c = shield.clone();
    let connect_c = connect.clone();
    let spinner_c = spinner.clone();
    let bn = banner.clone();
    connect.connect_clicked(move |_| {
        if active() {
            connect_c.set_sensitive(false);
            status_c.set_label("DISCONNECTING…");
            sub_c.set_label("Restoring direct network path");
            spinner_c.set_visible(true);
            spinner_c.start();
            let (tx, rx) = std::sync::mpsc::channel();
            thread::spawn(move || {
                let out = helper(&["disconnect"]);
                let _ = tx.send(out);
            });
            let status2 = status_c.clone();
            let sub2 = sub_c.clone();
            let shield2 = shield_c.clone();
            let button2 = connect_c.clone();
            let spin2 = spinner_c.clone();
            let banner2 = bn.clone();
            glib::timeout_add_local(Duration::from_millis(120), move || match rx.try_recv() {
                Ok(out) => {
                    spin2.stop();
                    spin2.set_visible(false);
                    button2.set_sensitive(true);
                    if out.contains("disconnected") && !out.contains("ERROR") {
                        status2.set_label("UNSECURED CONNECTION");
                        sub2.set_label("VPN is fully disconnected");
                        shield2.remove_css_class("shield-on");
                        button2.set_label("Secure my connection");
                        button2.remove_css_class("danger");
                        button2.add_css_class("primary");
                        notice(
                            &banner2,
                            "VPN disconnected and protected routes were removed",
                        );
                    } else {
                        status2.set_label("DISCONNECT NEEDS ATTENTION");
                        sub2.set_label("Open Diagnostics and verify teardown");
                        notice(&banner2, "Disconnect verification reported a problem");
                    }
                    glib::ControlFlow::Break
                }
                Err(std::sync::mpsc::TryRecvError::Empty) => glib::ControlFlow::Continue,
                Err(_) => glib::ControlFlow::Break,
            });
            return;
        }
        let user = saved_user();
        if user.is_empty() {
            status_c.set_label("ADD CREDENTIALS");
            sub_c.set_label("Open Settings → Credentials first");
            notice(&bn, "Surfshark service credentials are required");
            return;
        }
        let id = sel_conn.borrow().clone();
        let Some(loc) = by_id(&id) else { return };
        status_c.set_label("CONNECTING…");
        sub_c.set_label(&format!("Securing via {} · {}", loc.country, loc.city));
        shield_c.add_css_class("shield-busy");
        spinner_c.set_visible(true);
        spinner_c.start();
        connect_c.set_sensitive(false);
        let s = settings_conn.borrow().clone();
        let host = loc.host.to_string();
        let (tx, rx) = std::sync::mpsc::channel();
        thread::spawn(move || {
            let _ = tx.send(connect_vpn(&host, &user, &s));
        });
        let status2 = status_c.clone();
        let sub2 = sub_c.clone();
        let shield2 = shield_c.clone();
        let button2 = connect_c.clone();
        let spin2 = spinner_c.clone();
        let banner2 = bn.clone();
        glib::timeout_add_local(Duration::from_millis(120), move || match rx.try_recv() {
            Ok((ok, _log)) => {
                spin2.stop();
                spin2.set_visible(false);
                button2.set_sensitive(true);
                shield2.remove_css_class("shield-busy");
                if ok {
                    shield2.add_css_class("shield-on");
                    status2.set_label("SECURE CONNECTION");
                    sub2.set_label("Your traffic is protected");
                    button2.set_label("Disconnect");
                    button2.remove_css_class("primary");
                    button2.add_css_class("danger");
                    notice(&banner2, "Connected securely");
                } else {
                    status2.set_label("CONNECTION FAILED");
                    sub2.set_label("Open Diagnostics for details");
                    notice(&banner2, "Connection failed — Diagnostics has more detail");
                }
                glib::ControlFlow::Break
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => glib::ControlFlow::Continue,
            Err(_) => glib::ControlFlow::Break,
        });
    });

    // Live state polish: metrics and status follow the backend without reopening the app.
    let ip_l = ip_metric.clone();
    let exit_l = exit_metric.clone();
    let ping_l = ping_metric.clone();
    glib::timeout_add_local(Duration::from_secs(1), move || {
        ip_l.set_label(&value(STATE, "PUBLIC_IP").unwrap_or_else(|| "—".into()));
        exit_l.set_label(&value(STATE, "EXIT_COUNTRY").unwrap_or_else(|| "—".into()));
        ping_l.set_label(
            &value(LIVE, "LATENCY_MS")
                .map(|v| format!("{v} ms"))
                .unwrap_or_else(|| "—".into()),
        );
        glib::ControlFlow::Continue
    });

    let appwin = adw::ApplicationWindow::builder()
        .application(app)
        .title("MilMit Secure")
        .default_width(430)
        .default_height(760)
        .resizable(true)
        .build();
    root.append(&stack);
    appwin.set_content(Some(&root));
    appwin.present();
}
