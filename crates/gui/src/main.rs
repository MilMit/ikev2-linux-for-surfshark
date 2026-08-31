use adw::prelude::*;
use gtk::{glib, Orientation};
use std::net::Ipv4Addr;
use std::process::Command;
use std::rc::Rc;
use std::str::FromStr;

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

fn run_root(cmd: &str, args: &[&str]) -> String {
    let mut all = vec![cmd];
    all.extend_from_slice(args);
    run("pkexec", &all)
}

fn append_log(buffer: &gtk::TextBuffer, title: &str, body: &str) {
    let mut end = buffer.end_iter();
    buffer.insert(&mut end, &format!("\n=== {title} ===\n{body}\n"));
}

fn vpn_status() -> String {
    run_root("/usr/sbin/swanctl", &["--list-sas"])
}

fn tunnel_is_up(sas: &str) -> bool {
    sas.contains("ESTABLISHED") && sas.contains("INSTALLED") && sas.contains("remote 0.0.0.0/0")
}

fn valid_ipv4(value: &str) -> bool {
    Ipv4Addr::from_str(value).is_ok()
}

fn valid_iface(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 32
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.'))
}

fn parse_virtual_ip(sas: &str) -> Option<String> {
    for line in sas.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("local  ") {
            let candidate = rest.split_whitespace().next()?.split('/').next()?;
            if valid_ipv4(candidate) && candidate.starts_with("10.") {
                return Some(candidate.to_string());
            }
        }
    }

    for line in sas.lines() {
        if let (Some(open), Some(close)) = (line.find('['), line.find(']')) {
            if close > open {
                let candidate = &line[open + 1..close];
                if valid_ipv4(candidate) {
                    return Some(candidate.to_string());
                }
            }
        }
    }
    None
}

fn parse_remote_ip(sas: &str) -> Option<String> {
    for line in sas.lines() {
        let line = line.trim();
        if line.starts_with("remote '") {
            if let Some(at) = line.find(" @ ") {
                let rest = &line[at + 3..];
                let candidate = rest.split('[').next()?.trim();
                if valid_ipv4(candidate) {
                    return Some(candidate.to_string());
                }
            }
        }
    }
    None
}

#[derive(Debug, Clone)]
struct DefaultRoute {
    gateway: String,
    iface: String,
    source: String,
}

fn default_route() -> Result<DefaultRoute, String> {
    let text = run("/usr/sbin/ip", &["-4", "route", "show", "default"]);
    let line = text
        .lines()
        .find(|l| l.starts_with("default "))
        .ok_or_else(|| format!("No IPv4 default route found.\n{text}"))?;
    let parts: Vec<&str> = line.split_whitespace().collect();

    let gateway = parts
        .windows(2)
        .find(|w| w[0] == "via")
        .map(|w| w[1].to_string())
        .ok_or_else(|| format!("Could not parse gateway from: {line}"))?;
    let iface = parts
        .windows(2)
        .find(|w| w[0] == "dev")
        .map(|w| w[1].to_string())
        .ok_or_else(|| format!("Could not parse interface from: {line}"))?;

    let source = parts
        .windows(2)
        .find(|w| w[0] == "src")
        .map(|w| w[1].to_string())
        .or_else(|| {
            let probe = run("/usr/sbin/ip", &["-4", "route", "get", &gateway]);
            let p: Vec<&str> = probe.split_whitespace().collect();
            p.windows(2)
                .find(|w| w[0] == "src")
                .map(|w| w[1].to_string())
        })
        .ok_or_else(|| format!("Could not determine physical source address from: {line}"))?;

    if !valid_ipv4(&gateway) || !valid_ipv4(&source) || !valid_iface(&iface) {
        return Err(format!("Unsafe/invalid route values: {line}"));
    }

    Ok(DefaultRoute {
        gateway,
        iface,
        source,
    })
}

fn public_ipv4() -> String {
    run(
        "/usr/bin/curl",
        &["-4", "--max-time", "8", "-sS", "https://api.ipify.org"],
    )
    .trim()
    .to_string()
}

fn apply_network_integration(sas: &str, buffer: &gtk::TextBuffer) -> Result<(), String> {
    let vip = parse_virtual_ip(sas).ok_or("Could not extract the Surfshark virtual IPv4 address")?;
    let remote = parse_remote_ip(sas).ok_or("Could not extract the active Surfshark endpoint IPv4 address")?;
    let route = default_route()?;

    append_log(
        buffer,
        "NETWORK DISCOVERY",
        &format!(
            "Virtual IP: {vip}\nEndpoint: {remote}\nGateway: {}\nInterface: {}\nPhysical source: {}",
            route.gateway, route.iface, route.source
        ),
    );

    // strongSwan can report an installed VIP while the address is missing from
    // the kernel interface after MOBIKE/network changes. Repair it first.
    let vip_cidr = format!("{vip}/32");
    let address_result = run_root(
        "/usr/sbin/ip",
        &["address", "replace", &vip_cidr, "dev", &route.iface],
    );
    append_log(buffer, "ENSURE VIRTUAL IP", &address_result);

    // Keep the IKE endpoint outside the VPN policy-routing table so the tunnel
    // never tries to route its own UDP/4500 transport through itself.
    let endpoint_cidr = format!("{remote}/32");
    let endpoint_result = run_root(
        "/usr/sbin/ip",
        &[
            "route",
            "replace",
            "table",
            "220",
            &endpoint_cidr,
            "via",
            &route.gateway,
            "dev",
            &route.iface,
            "src",
            &route.source,
        ],
    );
    append_log(buffer, "ENDPOINT BYPASS ROUTE", &endpoint_result);

    // Route general IPv4 traffic with the assigned virtual source address.
    // That source matches the installed XFRM policy (VIP/32 -> 0.0.0.0/0).
    let default_result = run_root(
        "/usr/sbin/ip",
        &[
            "route",
            "replace",
            "table",
            "220",
            "default",
            "via",
            &route.gateway,
            "dev",
            &route.iface,
            "src",
            &vip,
        ],
    );
    append_log(buffer, "VPN DEFAULT ROUTE", &default_result);

    let table = run_root("/usr/sbin/ip", &["route", "show", "table", "220"]);
    append_log(buffer, "TABLE 220", &table);

    if default_result.contains("Invalid prefsrc") || default_result.contains("Error:") {
        return Err(format!("Failed to install VPN route:\n{default_result}"));
    }

    // Surfshark supplied these DNS addresses in the successful IKEv2 CP reply
    // observed during development. Applying them through systemd-resolved avoids
    // the resolvconf failure from charon-systemd on Ubuntu desktop.
    let dns_result = run_root(
        "/usr/bin/resolvectl",
        &["dns", &route.iface, "162.252.172.57", "149.154.159.92"],
    );
    append_log(buffer, "SURFSHARK DNS", &dns_result);
    let domain_result = run_root(
        "/usr/bin/resolvectl",
        &["domain", &route.iface, "~."],
    );
    append_log(buffer, "DNS DEFAULT DOMAIN", &domain_result);

    Ok(())
}

fn diagnostics() -> String {
    let mut out = String::new();
    let sections: [(&str, &str, &[&str]); 9] = [
        ("IPv4 route to 1.1.1.1", "/usr/sbin/ip", &["route", "get", "1.1.1.1"]),
        ("Table 220", "/usr/sbin/ip", &["route", "show", "table", "220"]),
        ("IPv4 rules", "/usr/sbin/ip", &["-4", "rule"]),
        ("IPv4 addresses", "/usr/sbin/ip", &["-4", "address"]),
        ("XFRM policies", "/usr/sbin/ip", &["xfrm", "policy"]),
        ("XFRM states", "/usr/sbin/ip", &["xfrm", "state"]),
        ("DNS status", "/usr/bin/resolvectl", &["status"]),
        ("Public IPv4", "/usr/bin/curl", &["-4", "--max-time", "8", "-sS", "https://api.ipify.org"]),
        ("Public IPv6", "/usr/bin/curl", &["-6", "--max-time", "8", "-sS", "https://api64.ipify.org"]),
    ];

    for (title, cmd, args) in sections {
        out.push_str(&format!("\n--- {title} ---\n"));
        if title.starts_with("XFRM") {
            out.push_str(&run_root(cmd, args));
        } else {
            out.push_str(&run(cmd, args));
        }
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

    let connect = gtk::Button::with_label("Connect / Repair");
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
        .min_content_height(380)
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
        .default_width(1000)
        .default_height(720)
        .content(&root)
        .build();

    let status = Rc::new(status);
    let buffer = Rc::new(buffer);

    let initial = vpn_status();
    if tunnel_is_up(&initial) {
        status.set_label("Tunnel established · network integration not verified");
        append_log(
            &buffer,
            "INITIAL STATUS",
            "An existing Surfshark IKEv2 tunnel is established. Use Connect / Repair to apply and verify Linux routing/DNS.",
        );
    } else {
        status.set_label("Disconnected");
    }
    append_log(&buffer, "SA STATUS", &initial);

    {
        let buffer = Rc::clone(&buffer);
        let status = Rc::clone(&status);
        connect.connect_clicked(move |_| {
            status.set_label("Connecting / repairing…");
            let before_ip = public_ipv4();
            append_log(&buffer, "PUBLIC IP BEFORE", &before_ip);

            let mut sas = vpn_status();
            if !tunnel_is_up(&sas) {
                let out = run_root(
                    "/usr/sbin/swanctl",
                    &["--initiate", "--child", "surfshark"],
                );
                append_log(&buffer, "IKEV2 CONNECT", &out);
                sas = vpn_status();
            } else {
                append_log(&buffer, "IKEV2 CONNECT", "Tunnel already exists; repairing Linux network integration instead of creating a duplicate CHILD_SA.");
            }

            append_log(&buffer, "SA STATUS", &sas);
            if !tunnel_is_up(&sas) {
                status.set_label("IKEv2 connection failed");
                return;
            }

            match apply_network_integration(&sas, &buffer) {
                Ok(()) => {
                    let after_ip = public_ipv4();
                    append_log(&buffer, "PUBLIC IP AFTER", &after_ip);
                    if !after_ip.is_empty()
                        && valid_ipv4(&after_ip)
                        && after_ip != before_ip
                    {
                        status.set_label(&format!("Connected · IPv4 {after_ip}"));
                    } else {
                        status.set_label("Tunnel up, but public IPv4 verification failed");
                        append_log(
                            &buffer,
                            "VERIFY FAILED",
                            "IKEv2 is established, but the public IPv4 did not change. Run diagnostics and share this log.",
                        );
                    }
                }
                Err(e) => {
                    status.set_label("Network integration failed");
                    append_log(&buffer, "NETWORK INTEGRATION ERROR", &e);
                }
            }
        });
    }

    {
        let buffer = Rc::clone(&buffer);
        let status = Rc::clone(&status);
        disconnect.connect_clicked(move |_| {
            let sas = vpn_status();
            if let Some(vip) = parse_virtual_ip(&sas) {
                if let Ok(route) = default_route() {
                    let _ = run_root("/usr/sbin/ip", &["route", "del", "table", "220", "default"]);
                    let _ = run_root("/usr/sbin/ip", &["address", "del", &format!("{vip}/32"), "dev", &route.iface]);
                    let dns = run_root("/usr/bin/resolvectl", &["revert", &route.iface]);
                    append_log(&buffer, "RESTORE DNS", &dns);
                }
            }
            let out = run_root(
                "/usr/sbin/swanctl",
                &["--terminate", "--ike", "surfshark-tr"],
            );
            append_log(&buffer, "DISCONNECT", &out);
            status.set_label("Disconnected");
        });
    }

    {
        let buffer = Rc::clone(&buffer);
        let status = Rc::clone(&status);
        refresh.connect_clicked(move |_| {
            let out = vpn_status();
            append_log(&buffer, "STATUS", &out);
            if tunnel_is_up(&out) {
                status.set_label("Tunnel established · verification required");
            } else {
                status.set_label("Disconnected");
            }
        });
    }

    {
        let buffer = Rc::clone(&buffer);
        logs.connect_clicked(move |_| {
            let out = run(
                "/usr/bin/journalctl",
                &["-u", "strongswan", "-n", "180", "--no-pager", "-o", "cat"],
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
