use std::process::Command;

const HELPER: &str = "/usr/libexec/milmit-surfshark-helper";
const ALLOWED: &[&str] = &[
    "status","connect","quick-connect","disconnect","watchdog-status","router-status","hotspot-status","hotspot-repair",
    "rules-status","rules-update","health","apply-safe","full-live-test","speed-test",
    "dns-test","mtu-test","save-lkg","support-bundle","emergency-stop","candidates",
    "route-explain","route-test","policy-add","policy-remove","router-options","device-set",
    "guest-start","guest-stop","guest-status","credentials-status","credentials-save"
];

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
        .invoke_handler(tauri::generate_handler![helper_action])
        .run(tauri::generate_context!())
        .expect("error while running MilMit Secure");
}
