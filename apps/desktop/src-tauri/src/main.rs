use serde::Serialize;
use std::process::Command;

const HELPER: &str = "/usr/libexec/milmit-surfshark-helper";
const LOCATION_SOURCE: &str = include_str!("../../../../crates/gui/src/locations.rs");
const ALLOWED: &[&str] = &[
    "status","connect","quick-connect","disconnect","watchdog-status","router-status","hotspot-status","hotspot-repair",
    "rules-status","rules-update","health","apply-safe","full-live-test","speed-test",
    "dns-test","mtu-test","save-lkg","support-bundle","emergency-stop","candidates",
    "route-explain","route-test","policy-add","policy-remove","router-options","device-set",
    "guest-start","guest-stop","guest-status","credentials-status","credentials-save"
];

#[derive(Clone, Serialize)]
struct UiLocation {
    id: String,
    country: String,
    city: String,
    host: String,
}

fn quoted_field(line: &str, field: &str) -> Option<String> {
    let marker = format!("{field}: \"");
    let start = line.find(&marker)? + marker.len();
    let rest = &line[start..];
    let end = rest.find('"')?;
    Some(rest[..end].to_string())
}

#[tauri::command]
fn list_locations() -> Vec<UiLocation> {
    LOCATION_SOURCE
        .lines()
        .filter(|line| line.trim_start().starts_with("Location {"))
        .filter_map(|line| {
            Some(UiLocation {
                id: quoted_field(line, "id")?,
                country: quoted_field(line, "country")?,
                city: quoted_field(line, "city")?,
                host: quoted_field(line, "host")?,
            })
        })
        .collect()
}

#[tauri::command]
fn ping_location(host: String) -> Result<Option<u32>, String> {
    if host.len() > 255 || !host.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-')) {
        return Err("invalid location hostname".into());
    }
    let output = Command::new("ping")
        .args(["-n", "-c", "1", "-W", "1", &host])
        .output()
        .map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Ok(None);
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let Some(pos) = text.find("time=") else { return Ok(None); };
    let rest = &text[pos + 5..];
    let end = rest.find(|c: char| c == ' ' || c == '\n').unwrap_or(rest.len());
    Ok(rest[..end].parse::<f64>().ok().map(|v| v.round() as u32))
}

#[tauri::command]
fn helper_action(action: String, args: Vec<String>) -> Result<String, String> {
    if !ALLOWED.contains(&action.as_str()) {
        return Err(format!("unsupported helper action: {action}"));
    }
    let output = Command::new("pkexec")
        .arg(HELPER)
        .arg(&action)
        .args(&args)
        .output()
        .map_err(|e| e.to_string())?;
    let mut text = String::from_utf8_lossy(&output.stdout).to_string();
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    if output.status.success() { Ok(text) } else { Err(text) }
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![helper_action, list_locations, ping_location])
        .run(tauri::generate_context!())
        .expect("error while running MilMit Secure");
}
