use adw::prelude::*;
use gtk::{glib, Orientation};
use std::process::Command;
use std::rc::Rc;

const PROFILE: &str = "MilMit Surfshark IKEv2";
const HOST: &str = "tr-ist.prod.surfshark.com";
const CA_CERT: &str = "/etc/swanctl/x509ca/surfshark_ikev2.crt";

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

fn append_log(buffer: &gtk::TextBuffer, title: &str, body: &str) {
    let mut end = buffer.end_iter();
    buffer.insert(&mut end, &format!("\n=== {title} ===\n{body}\n"));
}

fn profile_exists() -> bool {
    nm(&["-t", "-f", "NAME", "connection", "show"])
        .lines()
        .any(|line| line == PROFILE)
}

fn nm_active() -> bool {
    let out = nm(&["-t", "-f", "NAME,TYPE", "connection", "show", "--active"]);
    out.lines().any(|line| line == format!("{PROFILE}:vpn"))
}

fn nm_status() -> String {
    if !profile_exists() {
        return "VPN profile has not been created yet.".to_string();
    }
    nm(&[
        "-f",
        "GENERAL.STATE,GENERAL.VPN,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS",
        "connection",
        "show",
        PROFILE,
    ])
}

fn public_ip() -> String {
    run("curl", &["-4", "--max-time", "8", "-sS", "https://api.ipify.org"])
}

fn ensure_profile(username: &str, password: &str) -> String {
    let mut log = String::new();
    let desktop_user = std::env::var("USER").unwrap_or_else(|_| "".to_string());

    // Create the NetworkManager profile only once. Recreating/deleting it on
    // every connection forces PolicyKit to authorize repeatedly and also
    // discards the stored VPN secret.
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
    } else {
        log.push_str("[reuse existing NetworkManager profile]\n");
        log.push_str("Profile already exists; no privileged delete/recreate step is needed.\n");
    }

    let vpn_data = format!(
        "address = {HOST}, certificate = {CA_CERT}, encap = yes, ipcomp = no, method = eap, proposal = no, user = {username}, virtual = yes"
    );

    log.push_str("[configure IKEv2/EAP and persist VPN secret]\n");
    let args = vec![
        "connection".to_string(),
        "modify".to_string(),
        PROFILE.to_string(),
        "vpn.data".to_string(),
        vpn_data,
        "vpn.secrets".to_string(),
        format!("password={password}"),
        "ipv4.never-default".to_string(),
        "no".to_string(),
        "ipv6.method".to_string(),
        "disabled".to_string(),
    ];
    log.push_str(&run_owned("nmcli", &args));
    log.push('\n');

    log
}

fn diagnostics() -> String {
    let mut out = String::new();
    let sections: [(&str, &str, &[&str]); 7] = [
        (
            "Active NetworkManager connections",
            "nmcli",
            &["connection", "show", "--active"],
        ),
        ("VPN profile", "nmcli", &["connection", "show", PROFILE]),
        ("IPv4 routes", "ip", &["-4", "route"]),
        ("IPv4 rules", "ip", &["-4", "rule"]),
        ("DNS", "resolvectl", &["status"]),
        (
            "Public IPv4",
            "curl",
            &["-4", "--max-time", "8", "-sS", "https://api.ipify.org"],
        ),
        (
            "Public IPv6",
            "curl",
            &["-6", "--max-time", "5", "-sS", "https://api64.ipify.org"],
        ),
    ];
    for (title, cmd, args) in sections {
        out.push_str(&format!("\n--- {title} ---\n{}\n", run(cmd, args)));
    }
    out
}

fn main() -> glib::ExitCode {
    let app = adw::Application::builder()
        .application_id("net.milmit.SurfsharkIkev2")
        .build();
    app.connect_activate(build_ui);
    app.run()
}

fn build_ui(app: &adw::Application) {
    let header = adw::HeaderBar::new();
    let status = gtk::Label::builder()
        .label(if nm_active() {
            "Connected through NetworkManager"
        } else {
            "Disconnected"
        })
        .css_classes(["title-2"])
        .build();
    let endpoint = gtk::Label::builder()
        .label("Türkiye · Istanbul · IKEv2 · NetworkManager")
        .css_classes(["dim-label"])
        .build();

    let user = gtk::Entry::builder()
        .placeholder_text("Surfshark service username")
        .hexpand(true)
        .build();
    let pass = gtk::PasswordEntry::builder()
        .placeholder_text("Surfshark service password")
        .show_peek_icon(true)
        .hexpand(true)
        .build();

    let remember = gtk::CheckButton::with_label("Save credentials in NetworkManager");
    remember.set_active(true);
    remember.set_sensitive(false);

    let connect = gtk::Button::with_label("Connect");
    connect.add_css_class("suggested-action");
    let disconnect = gtk::Button::with_label("Disconnect");
    disconnect.add_css_class("destructive-action");
    let refresh = gtk::Button::with_label("Refresh");
    let diag = gtk::Button::with_label("Diagnostics");

    let fields = gtk::Box::new(Orientation::Vertical, 8);
    fields.append(&user);
    fields.append(&pass);
    fields.append(&remember);

    let actions = gtk::Box::new(Orientation::Horizontal, 8);
    actions.set_halign(gtk::Align::Center);
    actions.append(&connect);
    actions.append(&disconnect);
    actions.append(&refresh);
    actions.append(&diag);

    let text_view = gtk::TextView::builder()
        .editable(false)
        .monospace(true)
        .wrap_mode(gtk::WrapMode::WordChar)
        .top_margin(12)
        .bottom_margin(12)
        .left_margin(12)
        .right_margin(12)
        .build();
    let buffer = text_view.buffer();
    buffer.set_text("NetworkManager / strongSwan diagnostic log\n");

    let scroller = gtk::ScrolledWindow::builder()
        .vexpand(true)
        .hexpand(true)
        .min_content_height(340)
        .child(&text_view)
        .build();

    let content = gtk::Box::new(Orientation::Vertical, 12);
    content.set_margin_top(18);
    content.set_margin_bottom(18);
    content.set_margin_start(18);
    content.set_margin_end(18);
    content.append(&status);
    content.append(&endpoint);
    content.append(&fields);
    content.append(&actions);
    content.append(&scroller);

    let root = gtk::Box::new(Orientation::Vertical, 0);
    root.append(&header);
    root.append(&content);

    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title("Surfshark IKEv2 for Linux")
        .default_width(900)
        .default_height(700)
        .content(&root)
        .build();

    let status = Rc::new(status);
    let buffer = Rc::new(buffer);
    let user = Rc::new(user);
    let pass = Rc::new(pass);

    // Once a profile exists, future Connect/Disconnect operations are plain
    // nmcli actions. NetworkManager/PolicyKit handles the session permission,
    // so the app no longer launches pkexec on every button press.
    if profile_exists() {
        append_log(
            &buffer,
            "AUTHORIZATION",
            "Persistent VPN profile found. Connect/Disconnect will use NetworkManager directly without pkexec.",
        );
    }

    {
        let status = Rc::clone(&status);
        let buffer = Rc::clone(&buffer);
        let user = Rc::clone(&user);
        let pass = Rc::clone(&pass);
        connect.connect_clicked(move |_| {
            // If the saved profile already has credentials, first try it
            // directly. This is the normal path after initial setup.
            if profile_exists() && user.text().trim().is_empty() && pass.text().is_empty() {
                status.set_label("Connecting…");
                let before = public_ip();
                let up = nm(&["connection", "up", PROFILE]);
                append_log(&buffer, "NETWORKMANAGER CONNECT", &up);
                append_log(&buffer, "NETWORKMANAGER STATUS", &nm_status());
                let after = public_ip();
                append_log(&buffer, "PUBLIC IP AFTER", &after);
                if nm_active() && !after.trim().is_empty() && after.trim() != before.trim() {
                    status.set_label("Connected · Ubuntu VPN active");
                } else if nm_active() {
                    status.set_label("VPN active, IP verification failed");
                } else {
                    status.set_label("Connection failed");
                }
                return;
            }

            let username = user.text().trim().to_string();
            let password = pass.text().to_string();
            if username.is_empty() || password.is_empty() {
                status.set_label("Enter credentials once for initial setup");
                append_log(
                    &buffer,
                    "INPUT",
                    "Enter Surfshark service credentials once. They will be saved in the NetworkManager VPN profile for subsequent connections.",
                );
                return;
            }

            status.set_label("Preparing NetworkManager VPN…");
            let before = public_ip();
            append_log(&buffer, "PUBLIC IP BEFORE", &before);
            append_log(&buffer, "PROFILE SETUP", &ensure_profile(&username, &password));

            status.set_label("Connecting…");
            let up = nm(&["connection", "up", PROFILE]);
            append_log(&buffer, "NETWORKMANAGER CONNECT", &up);
            append_log(&buffer, "NETWORKMANAGER STATUS", &nm_status());

            let after = public_ip();
            append_log(&buffer, "PUBLIC IP AFTER", &after);
            if nm_active() && !after.trim().is_empty() && after.trim() != before.trim() {
                status.set_label("Connected · Ubuntu VPN active");
                pass.set_text("");
            } else if nm_active() {
                status.set_label("VPN active, IP verification failed");
            } else {
                status.set_label("Connection failed");
            }
        });
    }

    {
        let status = Rc::clone(&status);
        let buffer = Rc::clone(&buffer);
        disconnect.connect_clicked(move |_| {
            let out = nm(&["connection", "down", PROFILE]);
            append_log(&buffer, "DISCONNECT", &out);
            status.set_label(if nm_active() {
                "Still connected"
            } else {
                "Disconnected"
            });
        });
    }

    {
        let status = Rc::clone(&status);
        let buffer = Rc::clone(&buffer);
        refresh.connect_clicked(move |_| {
            append_log(&buffer, "STATUS", &nm_status());
            status.set_label(if nm_active() {
                "Connected through NetworkManager"
            } else {
                "Disconnected"
            });
        });
    }

    {
        let buffer = Rc::clone(&buffer);
        diag.connect_clicked(move |_| append_log(&buffer, "DIAGNOSTICS", &diagnostics()));
    }

    window.present();
}
