use adw::prelude::*;
use gtk::{glib, Orientation};
use std::process::Command;
use std::rc::Rc;

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
                format!("Command exited with status: {}", out.status)
            } else {
                text
            }
        }
        Err(e) => format!("Failed to run {cmd}: {e}"),
    }
}

fn append_log(buffer: &gtk::TextBuffer, title: &str, body: &str) {
    let mut end = buffer.end_iter();
    buffer.insert(&mut end, &format!("\n=== {title} ===\n{body}\n"));
}

fn vpn_status() -> String {
    run("pkexec", &["/usr/sbin/swanctl", "--list-sas"])
}

fn tunnel_is_up(sas: &str) -> bool {
    sas.contains("ESTABLISHED") && sas.contains("INSTALLED") && sas.contains("remote 0.0.0.0/0")
}

fn diagnostics() -> String {
    let mut out = String::new();

    let sections: [(&str, &str, &[&str]); 8] = [
        ("IPv4 route to 1.1.1.1", "ip", &["route", "get", "1.1.1.1"]),
        ("IPv4 routes", "ip", &["-4", "route"]),
        ("IPv4 rules", "ip", &["-4", "rule"]),
        ("XFRM policies", "ip", &["xfrm", "policy"]),
        ("XFRM states", "ip", &["xfrm", "state"]),
        ("DNS status", "resolvectl", &["status"]),
        ("Public IPv4", "curl", &["-4", "--max-time", "8", "-sS", "https://api.ipify.org"]),
        ("Public IPv6", "curl", &["-6", "--max-time", "8", "-sS", "https://api64.ipify.org"]),
    ];

    for (title, cmd, args) in sections {
        out.push_str(&format!("\n--- {title} ---\n"));
        out.push_str(&run(cmd, args));
        out.push('\n');
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
        .label("Checking status…")
        .css_classes(["title-2"])
        .build();

    let endpoint = gtk::Label::builder()
        .label("Türkiye · Istanbul · IKEv2")
        .css_classes(["dim-label"])
        .build();

    let connect = gtk::Button::with_label("Connect");
    connect.add_css_class("suggested-action");

    let disconnect = gtk::Button::with_label("Disconnect");
    disconnect.add_css_class("destructive-action");

    let refresh = gtk::Button::with_label("Refresh status");
    let logs = gtk::Button::with_label("Refresh logs");
    let diag = gtk::Button::with_label("Run diagnostics");

    let actions = gtk::Box::new(Orientation::Horizontal, 8);
    actions.set_halign(gtk::Align::Center);
    actions.append(&connect);
    actions.append(&disconnect);
    actions.append(&refresh);
    actions.append(&logs);
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
    buffer.set_text("Surfshark IKEv2 diagnostic log\n");

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
    content.append(&actions);
    content.append(&scroller);

    let root = gtk::Box::new(Orientation::Vertical, 0);
    root.append(&header);
    root.append(&content);

    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title("Surfshark IKEv2 for Linux")
        .default_width(960)
        .default_height(680)
        .content(&root)
        .build();

    let status = Rc::new(status);
    let buffer = Rc::new(buffer);

    // Initial state check. Do not initiate a duplicate CHILD_SA if the tunnel
    // already exists.
    let initial = vpn_status();
    if tunnel_is_up(&initial) {
        status.set_label("Connected");
        append_log(&buffer, "INITIAL STATUS", "An existing Surfshark IKEv2 tunnel is already established.");
    } else {
        status.set_label("Disconnected");
    }
    append_log(&buffer, "SA STATUS", &initial);

    {
        let buffer = Rc::clone(&buffer);
        let status = Rc::clone(&status);
        connect.connect_clicked(move |_| {
            let before = vpn_status();
            if tunnel_is_up(&before) {
                status.set_label("Connected");
                append_log(
                    &buffer,
                    "CONNECT",
                    "Tunnel is already established. Skipping duplicate initiate.",
                );
                append_log(&buffer, "SA STATUS", &before);
                return;
            }

            status.set_label("Connecting…");
            append_log(
                &buffer,
                "CONNECT",
                "Running: pkexec swanctl --initiate --child surfshark",
            );
            let out = run(
                "pkexec",
                &["/usr/sbin/swanctl", "--initiate", "--child", "surfshark"],
            );
            append_log(&buffer, "CONNECT RESULT", &out);

            let sas = vpn_status();
            if tunnel_is_up(&sas) {
                status.set_label("Connected");
            } else {
                status.set_label("Connection failed / incomplete");
            }
            append_log(&buffer, "SA STATUS", &sas);
        });
    }

    {
        let buffer = Rc::clone(&buffer);
        let status = Rc::clone(&status);
        disconnect.connect_clicked(move |_| {
            let out = run(
                "pkexec",
                &["/usr/sbin/swanctl", "--terminate", "--ike", "surfshark-tr"],
            );
            append_log(&buffer, "DISCONNECT", &out);
            let sas = vpn_status();
            if tunnel_is_up(&sas) {
                status.set_label("Still connected");
            } else {
                status.set_label("Disconnected");
            }
            append_log(&buffer, "SA STATUS", &sas);
        });
    }

    {
        let buffer = Rc::clone(&buffer);
        let status = Rc::clone(&status);
        refresh.connect_clicked(move |_| {
            let out = vpn_status();
            append_log(&buffer, "STATUS", &out);
            if tunnel_is_up(&out) {
                status.set_label("Connected");
            } else {
                status.set_label("Disconnected / incomplete");
            }
        });
    }

    {
        let buffer = Rc::clone(&buffer);
        logs.connect_clicked(move |_| {
            let out = run(
                "journalctl",
                &["-u", "strongswan", "-n", "160", "--no-pager", "-o", "cat"],
            );
            append_log(&buffer, "STRONGSWAN JOURNAL", &out);
        });
    }

    {
        let buffer = Rc::clone(&buffer);
        diag.connect_clicked(move |_| {
            append_log(&buffer, "DIAGNOSTICS", &diagnostics());
        });
    }

    window.present();
}
