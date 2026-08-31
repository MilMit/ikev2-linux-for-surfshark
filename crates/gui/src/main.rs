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
                if !text.is_empty() { text.push('\n'); }
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
        .label("Disconnected")
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

    let actions = gtk::Box::new(Orientation::Horizontal, 8);
    actions.set_halign(gtk::Align::Center);
    actions.append(&connect);
    actions.append(&disconnect);
    actions.append(&refresh);
    actions.append(&logs);

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

    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(&content));

    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title("Surfshark IKEv2 for Linux")
        .default_width(820)
        .default_height(620)
        .content(&toolbar)
        .build();

    let status = Rc::new(status);
    let buffer = Rc::new(buffer);

    {
        let buffer = Rc::clone(&buffer);
        let status = Rc::clone(&status);
        connect.connect_clicked(move |_| {
            status.set_label("Connecting…");
            append_log(&buffer, "CONNECT", "Running: pkexec swanctl --initiate --child surfshark");
            let out = run("pkexec", &["/usr/sbin/swanctl", "--initiate", "--child", "surfshark"]);
            append_log(&buffer, "CONNECT RESULT", &out);
            let sas = run("pkexec", &["/usr/sbin/swanctl", "--list-sas"]);
            if sas.contains("ESTABLISHED") && sas.contains("INSTALLED") {
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
            let out = run("pkexec", &["/usr/sbin/swanctl", "--terminate", "--ike", "surfshark-tr"]);
            append_log(&buffer, "DISCONNECT", &out);
            status.set_label("Disconnected");
        });
    }

    {
        let buffer = Rc::clone(&buffer);
        let status = Rc::clone(&status);
        refresh.connect_clicked(move |_| {
            let out = run("pkexec", &["/usr/sbin/swanctl", "--list-sas"]);
            append_log(&buffer, "STATUS", &out);
            if out.contains("ESTABLISHED") && out.contains("INSTALLED") {
                status.set_label("Connected");
            } else {
                status.set_label("Disconnected / incomplete");
            }
        });
    }

    {
        let buffer = Rc::clone(&buffer);
        logs.connect_clicked(move |_| {
            let out = run("journalctl", &["-u", "strongswan", "-n", "120", "--no-pager", "-o", "cat"]);
            append_log(&buffer, "STRONGSWAN JOURNAL", &out);
        });
    }

    window.present();
}
