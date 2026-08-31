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
                if !text.is_empty() { text.push('\n'); }
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

fn pk(args: &[&str]) -> String {
    let mut all = vec!["/usr/bin/nmcli"];
    all.extend_from_slice(args);
    run("pkexec", &all)
}

fn append_log(buffer: &gtk::TextBuffer, title: &str, body: &str) {
    let mut end = buffer.end_iter();
    buffer.insert(&mut end, &format!("\n=== {title} ===\n{body}\n"));
}

fn nm_active() -> bool {
    let out = run("nmcli", &["-t", "-f", "NAME,TYPE", "connection", "show", "--active"]);
    out.lines().any(|line| line == format!("{PROFILE}:vpn"))
}

fn nm_status() -> String {
    run("nmcli", &["-f", "GENERAL.STATE,GENERAL.VPN,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS", "connection", "show", PROFILE])
}

fn public_ip() -> String {
    run("curl", &["-4", "--max-time", "8", "-sS", "https://api.ipify.org"])
}

fn ensure_profile(username: &str, password: &str) -> String {
    let mut log = String::new();

    // Avoid a parallel swanctl-managed tunnel while NetworkManager takes over.
    let old = run("pkexec", &["/usr/sbin/swanctl", "--terminate", "--ike", "surfshark-tr"]);
    log.push_str("[legacy tunnel cleanup]\n");
    log.push_str(&old);
    log.push('\n');

    if run("nmcli", &["-t", "-f", "NAME", "connection", "show"])
        .lines()
        .any(|l| l == PROFILE)
    {
        log.push_str("[remove old NetworkManager profile]\n");
        log.push_str(&pk(&["connection", "delete", PROFILE]));
        log.push('\n');
    }

    log.push_str("[create NetworkManager strongSwan profile]\n");
    let add = pk(&[
        "connection", "add",
        "type", "vpn",
        "ifname", "--",
        "vpn-type", "strongswan",
        "connection.id", PROFILE,
        "connection.autoconnect", "no",
    ]);
    log.push_str(&add);
    log.push('\n');

    let vpn_data = format!(
        "address = {HOST}, certificate = {CA_CERT}, encap = yes, ipcomp = no, method = eap, proposal = no, user = {username}, virtual = yes"
    );

    log.push_str("[configure IKEv2/EAP]\n");
    log.push_str(&pk(&[
        "connection", "modify", PROFILE,
        "vpn.data", &vpn_data,
        "vpn.secrets", &format!("password={password}"),
        "ipv4.never-default", "no",
        "ipv6.method", "disabled",
    ]));
    log.push('\n');

    log
}

fn diagnostics() -> String {
    let mut out = String::new();
    let sections: [(&str, &str, &[&str]); 7] = [
        ("Active NetworkManager connections", "nmcli", &["connection", "show", "--active"]),
        ("VPN profile", "nmcli", &["connection", "show", PROFILE]),
        ("IPv4 routes", "ip", &["-4", "route"]),
        ("IPv4 rules", "ip", &["-4", "rule"]),
        ("DNS", "resolvectl", &["status"]),
        ("Public IPv4", "curl", &["-4", "--max-time", "8", "-sS", "https://api.ipify.org"]),
        ("Public IPv6", "curl", &["-6", "--max-time", "5", "-sS", "https://api64.ipify.org"]),
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
        .label(if nm_active() { "Connected through NetworkManager" } else { "Disconnected" })
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

    let connect = gtk::Button::with_label("Connect");
    connect.add_css_class("suggested-action");
    let disconnect = gtk::Button::with_label("Disconnect");
    disconnect.add_css_class("destructive-action");
    let refresh = gtk::Button::with_label("Refresh");
    let diag = gtk::Button::with_label("Diagnostics");

    let fields = gtk::Box::new(Orientation::Vertical, 8);
    fields.append(&user);
    fields.append(&pass);

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

    {
        let status = Rc::clone(&status);
        let buffer = Rc::clone(&buffer);
        let user = Rc::clone(&user);
        let pass = Rc::clone(&pass);
        connect.connect_clicked(move |_| {
            let username = user.text().trim().to_string();
            let password = pass.text().to_string();
            if username.is_empty() || password.is_empty() {
                status.set_label("Enter service credentials");
                append_log(&buffer, "INPUT", "Service username and password are required.");
                return;
            }

            status.set_label("Preparing NetworkManager VPN…");
            let before = public_ip();
            append_log(&buffer, "PUBLIC IP BEFORE", &before);
            append_log(&buffer, "PROFILE SETUP", &ensure_profile(&username, &password));

            status.set_label("Connecting…");
            let up = pk(&["connection", "up", PROFILE]);
            append_log(&buffer, "NETWORKMANAGER CONNECT", &up);
            append_log(&buffer, "NETWORKMANAGER STATUS", &nm_status());

            let after = public_ip();
            append_log(&buffer, "PUBLIC IP AFTER", &after);
            if nm_active() && !after.trim().is_empty() && after.trim() != before.trim() {
                status.set_label("Connected · Ubuntu VPN active");
                // Remove the password from the widget after NetworkManager has received it.
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
            let out = pk(&["connection", "down", PROFILE]);
            append_log(&buffer, "DISCONNECT", &out);
            status.set_label(if nm_active() { "Still connected" } else { "Disconnected" });
        });
    }

    {
        let status = Rc::clone(&status);
        let buffer = Rc::clone(&buffer);
        refresh.connect_clicked(move |_| {
            append_log(&buffer, "STATUS", &nm_status());
            status.set_label(if nm_active() { "Connected through NetworkManager" } else { "Disconnected" });
        });
    }

    {
        let buffer = Rc::clone(&buffer);
        diag.connect_clicked(move |_| append_log(&buffer, "DIAGNOSTICS", &diagnostics()));
    }

    window.present();
}
