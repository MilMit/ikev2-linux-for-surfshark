use serde::Serialize;
use std::process::Command;

#[derive(Serialize)]
pub struct NetworkDiagnostics {
    pub interfaces: Vec<String>,
    pub vpn_interface: Option<String>,
    pub default_route: String,
    pub dns_status: String,
    pub ipv6_status: String,
}

fn cmd_output(cmd: &str, args: &[&str]) -> String {
    Command::new(cmd)
        .args(args)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_else(|_| String::new())
}

#[tauri::command]
pub fn network_diagnostics() -> NetworkDiagnostics {
    let links = cmd_output("ip", &["-br", "link"]);
    let routes = cmd_output("ip", &["-4", "route"]);
    let vpn = links
        .lines()
        .find(|l| l.contains("milmit") || l.contains("xfrm"))
        .map(|l| l.split_whitespace().next().unwrap_or("").to_string());

    NetworkDiagnostics {
        interfaces: links.lines().map(|x| x.to_string()).collect(),
        vpn_interface: vpn,
        default_route: routes
            .lines()
            .find(|x| x.starts_with("default"))
            .unwrap_or("not found")
            .to_string(),
        dns_status: cmd_output("resolvectl", &["status"]),
        ipv6_status: cmd_output("ip", &["-6", "route"]),
    }
}
