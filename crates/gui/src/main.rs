mod locations;

use adw::prelude::*;
use gtk::{glib, Orientation};
use locations::{by_host, by_id, LOCATIONS};
use std::process::Command;
use std::rc::Rc;
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

const PROFILE: &str = "MilMit Surfshark IKEv2";
const CA_CERT: &str = "/etc/swanctl/x509ca/surfshark_ikev2.crt";

#[derive(Debug)]
enum Event {
    Busy(String),
    Log(String, String),
    Connected(String, String),
    Disconnected,
    Failed(String),
    Refreshed(bool, String),
}

fn run(cmd: &str, args: &[&str]) -> String {
    match Command::new(cmd).args(args).output() {
        Ok(out) => {
            let mut text = String::new();
            if !out.stdout.is_empty() {
                text.push_str(&String::from_utf8_lossy(&out.stdout));
            }
            if !out.stderr.is_empty() {
                if !text.is_empty() {
                    text.push('\n');
                }
                text.push_str(&String::from_utf8_lossy(&out.stderr));
            }
            if text.trim().is_empty() {
                format!("exit: {}", out.status)
            } else {
                text
            }
        }
        Err(e) => format!("Failed to run {cmd}: {e}"),
    }
}

fn run_owned(cmd: &str, args: &[String]) -> String {
    let refs: Vec<&str> = args.iter().map(String::as_str).collect();
    run(cmd, &refs)
}

fn nm(args: &[&str]) -> String {
    run("nmcli", args)
}

fn profile_exists() -> bool {
    nm(&["-t", "-f", "NAME", "connection", "show"])
        .lines()
        .any(|line| line == PROFILE)
}

fn nm_active() -> bool {
    nm(&["-t", "-f", "NAME,TYPE", "connection", "show", "--active"])
        .lines()
        .any(|line| line == format!("{PROFILE}:vpn"))
}

fn public_ip() -> String {
    run(
        "curl",
        &["-4", "--max-time", "8", "-sS", "https://api.ipify.org"],
    )
}

fn vpn_data() -> String {
    if !profile_exists() {
        return String::new();
    }
    nm(&["-g", "vpn.data", "connection", "show", PROFILE])
}

fn parse_vpn_value(data: &str, key: &str) -> Option<String> {
    data.split(',').find_map(|part| {
        let mut pieces = part.trim().splitn(2, '=');
        let k = pieces.next()?.trim();
        let v = pieces.next()?.trim();
        (k == key && !v.is_empty()).then(|| v.to_string())
    })
}

fn saved_username() -> Option<String> {
    parse_vpn_value(&vpn_data(), "user")
}

fn saved_host() -> Option<String> {
    parse_vpn_value(&vpn_data(), "address")
}

fn nm_status() -> String {
    if !profile_exists() {
        return "VPN profile has not been created yet.".to_string();
    }
    nm(&[
        "-f",
        "GENERAL.STATE,GENERAL.VPN,connection.id,connection.uuid,vpn.service-type,vpn.data,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS",
        "connection",
        "show",
        PROFILE,
    ])
}

fn failure_log() -> String {
    run(
        "journalctl",
        &[
            "-b",
            "-u",
            "NetworkManager",
            "--no-pager",
            "-n",
            "120",
            "-o",
            "short-precise",
        ],
    )
}

fn configure_profile(host: &str, username: &str, password: Option<&str>) -> String {
    let mut log = String::new();
    let desktop_user = std::env::var("USER").unwrap_or_default();

    if !profile_exists() {
        log.push_str("[create persistent NetworkManager profile]\n");
        let mut args = vec![
            "connection".to_string(),
            "add".to_string(),
            "type".to_string(),
            "vpn".to_string(),
            "ifname".to_string(),
            "--".to_string(),
            "vpn-type".to_string(),
            "strongswan".to_string(),
            "connection.id".to_string(),
            PROFILE.to_string(),
            "connection.autoconnect".to_string(),
            "no".to_string(),
        ];
        if !desktop_user.is_empty() {
            args.push("connection.permissions".to_string());
            args.push(format!("user:{desktop_user}"));
        }
        log.push_str(&run_owned("nmcli", &args));
        log.push('\n');
    }

    let data = format!(
        "address = {host}, server-identity = {host}, certificate = {CA_CERT}, encap = yes, ipcomp = no, method = eap, proposal = no, user = {username}, virtual = yes"
    );

    let mut args = vec![
        "connection".to_string(),
        "modify".to_string(),
        PROFILE.to_string(),
        "vpn.data".to_string(),
        data,
        "ipv4.never-default".to_string(),
        "no".to_string(),
        "ipv6.method".to_string(),
        "disabled".to_string(),
    ];

    if let Some(password) = password {
        args.push("vpn.secrets".to_string());
        args.push(format!("password={password}"));
    }

    log.push_str("[configure IKEv2 location and credentials]\n");
    log.push_str(&run_owned("nmcli", &args));
    log
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
         .location-box { padding: 14px; border-radius: 14px; }\n\
         .primary-connect { min-height: 44px; padding-left: 30px; padding-right: 30px; }\n\
         .diag-box { font-size: 12px; }",
    );
    if let Some(display) = gtk::gdk::Display::default() {
        gtk::style_context_add_provider_for_display(
            &display,
            &provider,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }
}

fn main() -> glib::ExitCode {
    let app = adw::Application::builder()
        .application_id("net.milmit.SurfsharkIkev2")
        .build();
    app.connect_activate(build_ui);
    app.run()
}

fn build_ui(app: &adw::Application) {
    install_css();

    let header = adw::HeaderBar::new();
    let title = adw::WindowTitle::new("Surfshark IKEv2", "Unofficial Linux client by MilMit");
    header.set_title_widget(Some(&title));

    let status = gtk::Label::builder()
        .label(if nm_active() { "Connected" } else { "Ready" })
        .css_classes(["status-pill"])
        .build();
    let hero_title = gtk::Label::builder()
        .label("Private. Fast. Native IKEv2.")
        .halign(gtk::Align::Start)
        .css_classes(["hero-title"])
        .build();
    let hero_subtitle = gtk::Label::builder()
        .label("Choose a Surfshark location and connect through Ubuntu NetworkManager.")
        .halign(gtk::Align::Start)
        .wrap(true)
        .css_classes(["dim-label"])
        .build();

    let spinner = gtk::Spinner::new();
    let hero_top = gtk::Box::new(Orientation::Horizontal, 12);
    hero_top.append(&status);
    hero_top.append(&spinner);

    let hero = gtk::Box::new(Orientation::Vertical, 10);
    hero.add_css_class("hero");
    hero.append(&hero_top);
    hero.append(&hero_title);
    hero.append(&hero_subtitle);

    let location_label = gtk::Label::builder()
        .label("Location")
        .halign(gtk::Align::Start)
        .css_classes(["heading"])
        .build();
    let location = gtk::ComboBoxText::new();
    location.set_hexpand(true);
    for item in LOCATIONS {
        location.append(Some(item.id), item.label);
    }

    if let Some(host) = saved_host() {
        if let Some(saved) = by_host(&host) {
            location.set_active_id(Some(saved.id));
        } else {
            location.set_active(Some(0));
        }
    } else {
        location.set_active(Some(0));
    }

    let location_box = gtk::Box::new(Orientation::Vertical, 7);
    location_box.add_css_class("location-box");
    location_box.append(&location_label);
    location_box.append(&location);

    let user = gtk::Entry::builder()
        .placeholder_text("Surfshark service username")
        .hexpand(true)
        .build();
    if let Some(name) = saved_username() {
        user.set_text(&name);
    }
    let pass = gtk::PasswordEntry::builder()
        .placeholder_text(if profile_exists() {
            "Password saved · leave blank to reuse"
        } else {
            "Surfshark service password"
        })
        .show_peek_icon(true)
        .hexpand(true)
        .build();
    let creds_note = gtk::Label::builder()
        .label(if profile_exists() {
            "✓ Credentials are stored in NetworkManager. Password is not shown back to the app."
        } else {
            "Enter service credentials once. They will be saved by NetworkManager."
        })
        .halign(gtk::Align::Start)
        .wrap(true)
        .css_classes(["dim-label"])
        .build();

    let credentials = gtk::Box::new(Orientation::Vertical, 8);
    credentials.append(&user);
    credentials.append(&pass);
    credentials.append(&creds_note);

    let connect = gtk::Button::with_label("Connect");
    connect.add_css_class("suggested-action");
    connect.add_css_class("primary-connect");
    let disconnect = gtk::Button::with_label("Disconnect");
    disconnect.add_css_class("destructive-action");
    let refresh = gtk::Button::with_label("Refresh status");

    let actions = gtk::Box::new(Orientation::Horizontal, 8);
    actions.set_halign(gtk::Align::Center);
    actions.append(&connect);
    actions.append(&disconnect);
    actions.append(&refresh);

    let ip_label = gtk::Label::builder()
        .label("Public IP: —")
        .halign(gtk::Align::Center)
        .css_classes(["dim-label"])
        .build();

    let text_view = gtk::TextView::builder()
        .editable(false)
        .monospace(true)
        .wrap_mode(gtk::WrapMode::WordChar)
        .top_margin(12)
        .bottom_margin(12)
        .left_margin(12)
        .right_margin(12)
        .css_classes(["diag-box"])
        .build();
    let buffer = text_view.buffer();
    buffer.set_text("Surfshark IKEv2 diagnostic log\n");

    let scroller = gtk::ScrolledWindow::builder()
        .vexpand(true)
        .hexpand(true)
        .min_content_height(240)
        .child(&text_view)
        .build();
    let expander = gtk::Expander::new(Some("Advanced diagnostics"));
    expander.set_child(Some(&scroller));

    let content = gtk::Box::new(Orientation::Vertical, 16);
    content.set_margin_top(18);
    content.set_margin_bottom(18);
    content.set_margin_start(22);
    content.set_margin_end(22);
    content.append(&hero);
    content.append(&location_box);
    content.append(&credentials);
    content.append(&actions);
    content.append(&ip_label);
    content.append(&expander);

    let root = gtk::Box::new(Orientation::Vertical, 0);
    root.append(&header);
    root.append(&content);

    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title("Surfshark IKEv2 for Linux")
        .default_width(720)
        .default_height(680)
        .content(&root)
        .build();

    let (tx, rx) = mpsc::channel::<Event>();

    let status = Rc::new(status);
    let spinner = Rc::new(spinner);
    let connect = Rc::new(connect);
    let disconnect = Rc::new(disconnect);
    let refresh = Rc::new(refresh);
    let buffer = Rc::new(buffer);
    let ip_label = Rc::new(ip_label);
    let creds_note = Rc::new(creds_note);
    let pass = Rc::new(pass);
    let user = Rc::new(user);
    let location = Rc::new(location);

    {
        let status = Rc::clone(&status);
        let spinner = Rc::clone(&spinner);
        let connect = Rc::clone(&connect);
        let disconnect = Rc::clone(&disconnect);
        let refresh = Rc::clone(&refresh);
        let buffer = Rc::clone(&buffer);
        let ip_label = Rc::clone(&ip_label);
        let creds_note = Rc::clone(&creds_note);
        let pass = Rc::clone(&pass);

        glib::timeout_add_local(Duration::from_millis(80), move || {
            while let Ok(event) = rx.try_recv() {
                match event {
                    Event::Busy(message) => {
                        status.set_label(&message);
                        spinner.start();
                        connect.set_sensitive(false);
                        disconnect.set_sensitive(false);
                        refresh.set_sensitive(false);
                    }
                    Event::Log(title, body) => append_log(&buffer, &title, &body),
                    Event::Connected(ip, label) => {
                        spinner.stop();
                        status.set_label("Connected · Ubuntu VPN active");
                        ip_label.set_label(&format!("{label}  ·  Public IP: {ip}"));
                        connect.set_sensitive(true);
                        disconnect.set_sensitive(true);
                        refresh.set_sensitive(true);
                        pass.set_text("");
                        pass.set_placeholder_text(Some("Password saved · leave blank to reuse"));
                        creds_note.set_label("✓ Credentials saved in NetworkManager");
                    }
                    Event::Disconnected => {
                        spinner.stop();
                        status.set_label("Disconnected");
                        ip_label.set_label("Public IP: —");
                        connect.set_sensitive(true);
                        disconnect.set_sensitive(true);
                        refresh.set_sensitive(true);
                    }
                    Event::Failed(message) => {
                        spinner.stop();
                        status.set_label("Connection failed");
                        connect.set_sensitive(true);
                        disconnect.set_sensitive(true);
                        refresh.set_sensitive(true);
                        append_log(&buffer, "ERROR", &message);
                    }
                    Event::Refreshed(active, text) => {
                        spinner.stop();
                        status.set_label(if active { "Connected" } else { "Disconnected" });
                        connect.set_sensitive(true);
                        disconnect.set_sensitive(true);
                        refresh.set_sensitive(true);
                        append_log(&buffer, "STATUS", &text);
                    }
                }
            }
            glib::ControlFlow::Continue
        });
    }

    {
        let tx = tx.clone();
        let user = Rc::clone(&user);
        let pass = Rc::clone(&pass);
        let location = Rc::clone(&location);
        connect.connect_clicked(move |_| {
            let id = location
                .active_id()
                .map(|s| s.to_string())
                .unwrap_or_else(|| "tr-ist".to_string());
            let Some(selected) = by_id(&id) else { return; };
            let username = user.text().trim().to_string();
            let password = pass.text().to_string();
            let tx = tx.clone();

            thread::spawn(move || {
                let _ = tx.send(Event::Busy(format!("Connecting to {}…", selected.city)));
                let before = public_ip();

                if nm_active() {
                    let down = nm(&["connection", "down", PROFILE]);
                    let _ = tx.send(Event::Log("SWITCH LOCATION".into(), down));
                }

                let effective_user = if username.is_empty() {
                    saved_username().unwrap_or_default()
                } else {
                    username
                };

                if effective_user.is_empty() {
                    let _ = tx.send(Event::Failed(
                        "Surfshark service username is required for first setup.".into(),
                    ));
                    return;
                }

                let password_opt = if password.is_empty() {
                    if profile_exists() { None } else { Some("") }
                } else {
                    Some(password.as_str())
                };

                if password_opt == Some("") {
                    let _ = tx.send(Event::Failed(
                        "Surfshark service password is required for first setup.".into(),
                    ));
                    return;
                }

                let setup = configure_profile(selected.host, &effective_user, password_opt);
                let _ = tx.send(Event::Log("PROFILE SETUP".into(), setup));

                let up = nm(&["connection", "up", PROFILE]);
                let _ = tx.send(Event::Log("NETWORKMANAGER CONNECT".into(), up));

                if !nm_active() {
                    let log = failure_log();
                    let _ = tx.send(Event::Log("NETWORKMANAGER FAILURE LOG".into(), log));
                    let _ = tx.send(Event::Failed("NetworkManager did not activate the VPN.".into()));
                    return;
                }

                let after = public_ip();
                let _ = tx.send(Event::Log("PUBLIC IP BEFORE".into(), before.clone()));
                let _ = tx.send(Event::Log("PUBLIC IP AFTER".into(), after.clone()));

                if after.trim().is_empty() || after.trim() == before.trim() {
                    let _ = tx.send(Event::Failed(
                        "VPN is active but public IPv4 did not change.".into(),
                    ));
                    return;
                }

                let _ = tx.send(Event::Connected(after.trim().to_string(), selected.label.into()));
            });
        });
    }

    {
        let tx = tx.clone();
        disconnect.connect_clicked(move |_| {
            let tx = tx.clone();
            thread::spawn(move || {
                let _ = tx.send(Event::Busy("Disconnecting…".into()));
                let out = nm(&["connection", "down", PROFILE]);
                let _ = tx.send(Event::Log("DISCONNECT".into(), out));
                if nm_active() {
                    let _ = tx.send(Event::Failed("VPN still appears active.".into()));
                } else {
                    let _ = tx.send(Event::Disconnected);
                }
            });
        });
    }

    {
        let tx = tx.clone();
        refresh.connect_clicked(move |_| {
            let tx = tx.clone();
            thread::spawn(move || {
                let _ = tx.send(Event::Busy("Refreshing…".into()));
                let active = nm_active();
                let text = nm_status();
                let _ = tx.send(Event::Refreshed(active, text));
            });
        });
    }

    window.present();
}
