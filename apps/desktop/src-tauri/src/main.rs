use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashSet;
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{atomic::{AtomicU64, Ordering}, Mutex};
use std::thread;
use std::time::Instant;

mod runtime;
mod network_diagnostics;
#[path = "../../../../crates/gui/src/bundled_endpoints.rs"]
mod bundled_endpoints;

const HELPER: &str = "/usr/libexec/milmit-surfshark-helper";
const LOCATION_SOURCE: &str = include_str!("../../../../crates/gui/src/locations.rs");
const STATE: &str = "/run/milmit-surfshark/restricted.state";
const LIVE: &str = "/run/milmit-surfshark/live.state";
const ENGINE_STATE: &str = "/run/milmit-surfshark/engine-v3.json";
const ENGINE_EVENTS: &str = "/run/milmit-surfshark/engine-v3.events";
const ENDPOINT_HEALTH: &str = "/var/lib/milmit-surfshark/endpoint-health.json";
const USAGE: &str = "/var/lib/milmit-surfshark/traffic-usage.state";
const ALLOWED: &[&str] = &[
    "status", "connect", "quick-connect", "connect-saved", "engine-connect", "engine-status", "disconnect", "cancel-connect", "watchdog-status",
    "router-status", "hotspot-status", "hotspot-repair", "hotspot-doctor", "rules-status",
    "rules-update", "health", "apply-safe", "full-live-test", "speed-test", "dns-test",
    "mtu-test", "save-lkg", "support-bundle", "emergency-stop", "candidates", "route-explain",
    "route-test", "policy-add", "policy-remove", "router-options", "device-set", "guest-start",
    "guest-stop", "guest-status", "credentials-status", "credentials-save", "desktop-status",
    "auto-connect", "lockdown", "lockdown-allow-iran", "lockdown-apply", "app-direct-launch",
    "dns-repair", "chatgpt-test", "routing-mode-status", "set-routing-mode",
    "custom-rules-get", "custom-rules-add", "custom-rules-remove",
];

static CONNECT_GENERATION: AtomicU64 = AtomicU64::new(0);
static ATTEMPT_LOG: Mutex<String> = Mutex::new(String::new());

#[derive(Clone, Serialize)]
struct UiLocation { id: String, country: String, city: String, host: String }
#[derive(Clone, Serialize)]
struct ConnectionState { connected: bool, state: String, public_ip: Option<String>, exit_country: Option<String>, latency_ms: Option<u32> }
#[derive(Clone, Deserialize)]
struct PingRequest { id: String, host: String }
#[derive(Clone, Serialize)]
struct PingResult { id: String, ping: Option<u32> }
#[derive(Clone, Serialize)]
struct TrafficSnapshot { connected: bool, rx_bytes: u64, tx_bytes: u64, rx_bps: u64, tx_bps: u64, all_rx_bytes: u64, all_tx_bytes: u64, day_rx_bytes: u64, day_tx_bytes: u64, month_rx_bytes: u64, month_tx_bytes: u64 }
#[derive(Clone, Serialize)]
struct DesktopApp { id: String, name: String, icon: String, exec: String }

fn attempt_clear() { if let Ok(mut log) = ATTEMPT_LOG.lock() { log.clear(); } }
fn sanitize_backend(text: &str) -> String {
    let mut out = Vec::<String>::new();
    let mut local_auth = false;
    for line in text.lines() {
        let l = line.to_ascii_lowercase();
        if l.contains("local eap_mschapv2 authentication") { local_auth = true; out.push(line.to_string()); continue; }
        if l.contains("remote public key authentication") { local_auth = false; }
        if local_auth && (line.trim_start().starts_with("id:") || line.trim_start().starts_with("eap_id:")) {
            out.push(format!("{}[redacted]", &line[..line.len() - line.trim_start().len()])); continue;
        }
        if l.contains("service_pass") || l.contains("service_user") || l.contains("password") || l.contains("secret") || l.contains("eap identity") || l.contains("eap_identity") || l.contains("authentication of '") || line.trim_start().starts_with("local  '") { continue; }
        out.push(line.to_string());
    }
    if out.len() > 180 {
        let mut compact = out[..60].to_vec();
        compact.push(format!("... {} diagnostic lines omitted ...", out.len() - 180));
        compact.extend_from_slice(&out[out.len() - 120..]); compact.join("\n")
    } else { out.join("\n") }
}
fn attempt_add(text: &str) {
    if let Ok(mut log) = ATTEMPT_LOG.lock() {
        if !log.is_empty() { log.push('\n'); }
        log.push_str(text);
        if log.len() > 48_000 { let keep_from = log.len().saturating_sub(40_000); *log = log[keep_from..].to_string(); }
    }
}
fn engine_events_pretty() -> String {
    let Ok(raw) = fs::read_to_string(ENGINE_EVENTS) else { return String::new(); };
    let mut out=Vec::new();
    for line in raw.lines() {
        if let Ok(v)=serde_json::from_str::<Value>(line) {
            let phase=v.get("phase").and_then(Value::as_str).unwrap_or("ENGINE");
            let msg=v.get("message").and_then(Value::as_str).unwrap_or("");
            let proto=v.get("protocol").and_then(Value::as_str).unwrap_or("");
            let endpoint=v.get("endpoint").and_then(Value::as_str).unwrap_or("");
            out.push(format!("ENGINE [{phase}] {msg}{}{}", if proto.is_empty(){String::new()}else{format!(" protocol={proto}")}, if endpoint.is_empty(){String::new()}else{format!(" endpoint={endpoint}")}));
        }
    }
    out.join("\n")
}
#[tauri::command]
fn connection_attempt_log() -> String {
    let base=ATTEMPT_LOG.lock().map(|v| v.clone()).unwrap_or_default();
    let events=engine_events_pretty();
    if events.is_empty(){base}else if base.is_empty(){events}else{format!("{base}\n{events}")}
}

fn quoted_field(line: &str, field: &str) -> Option<String> {
    let marker = format!("{field}: \""); let start = line.find(&marker)? + marker.len(); let rest = &line[start..]; let end = rest.find('"')?; Some(rest[..end].to_string())
}
fn parse_locations() -> Vec<UiLocation> {
    LOCATION_SOURCE.lines().filter(|line| line.trim_start().starts_with("Location {")).filter_map(|line| Some(UiLocation {
        id: quoted_field(line, "id")?, country: quoted_field(line, "country")?, city: quoted_field(line, "city")?, host: quoted_field(line, "host")?,
    })).collect()
}
#[tauri::command]
fn list_locations() -> Vec<UiLocation> { parse_locations() }
fn valid_host(host: &str) -> bool { host.len() <= 255 && host.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-')) }
fn candidate_ips(host: &str) -> Vec<String> {
    let mut out = Vec::<String>::new();
    if host == "ee-tll.prod.surfshark.com" { out.push("185.174.159.123".into()); }
    for ip in bundled_endpoints::for_host(host) {
        if !out.iter().any(|x| x == ip) { out.push((*ip).to_string()); }
    }
    out
}
fn ping_target(host: &str) -> String { candidate_ips(host).into_iter().next().unwrap_or_else(|| host.to_string()) }
fn recent_health_blocks(host: &str, endpoint: &str) -> bool {
    let fresh = fs::metadata(ENDPOINT_HEALTH).and_then(|m| m.modified()).ok().and_then(|t| t.elapsed().ok()).map(|d| d.as_secs() < 15 * 60).unwrap_or(false);
    if !fresh { return false; }
    let Ok(raw) = fs::read_to_string(ENDPOINT_HEALTH) else { return false; };
    let Ok(v) = serde_json::from_str::<Value>(&raw) else { return false; };
    let key = format!("ikev2:{host}:{endpoint}");
    let outcome = v.get("endpoints").and_then(|x| x.get(&key)).and_then(|x| x.get("last_outcome")).and_then(Value::as_str).unwrap_or("");
    matches!(outcome, "DATA_PATH_BLOCKED" | "HANDSHAKE_FAILED" | "TIMEOUT" | "POST_TUNNEL_FAILED" | "AUTH_FAILED")
}
fn ike_probe_ip(target: &str, nat_t: bool) -> Result<Option<u32>, String> {
    let mut cmd = Command::new("ike-scan");
    cmd.arg("--ikev2");
    if nat_t { cmd.arg("--nat-t"); }
    cmd.args(["--sport=0", "--retry=1", "--timeout=1200", "--nodns", "--quiet", target]);
    let started = Instant::now();
    let output = cmd.output().map_err(|e| format!("ike-scan unavailable: {e}"))?;
    let elapsed = started.elapsed().as_millis().min(u32::MAX as u128) as u32;
    let mut text = String::from_utf8_lossy(&output.stdout).to_string();
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    let responded = text.lines().any(|line| line.trim_start().starts_with(target));
    Ok(responded.then_some(elapsed.max(1)))
}
fn ike_latency(host: &str) -> Result<Option<u32>, String> {
    let candidates = candidate_ips(host);
    if candidates.is_empty() { return Ok(None); }
    let mut best: Option<u32> = None;
    for ip in candidates {
        if recent_health_blocks(host, &ip) { continue; }
        let measured = ike_probe_ip(&ip, false)?.or(ike_probe_ip(&ip, true)?);
        if let Some(ms) = measured { best = Some(best.map_or(ms, |b| b.min(ms))); }
    }
    Ok(best)
}
#[tauri::command]
async fn ping_location(host: String) -> Result<Option<u32>, String> {
    if !valid_host(&host) { return Err("invalid location hostname".into()); }
    tauri::async_runtime::spawn_blocking(move || ike_latency(&host)).await.map_err(|e| e.to_string())?
}
fn ping_batch_blocking(items: Vec<PingRequest>) -> Result<Vec<PingResult>, String> {
    if items.len() > 256 { return Err("too many ping targets".into()); }
    if items.iter().any(|x| x.id.len() > 64 || !valid_host(&x.host)) { return Err("invalid ping target".into()); }
    let mut out = Vec::with_capacity(items.len());
    for chunk in items.chunks(6) {
        let handles = chunk.iter().cloned().map(|item| thread::spawn(move || PingResult { id: item.id, ping: ike_latency(&item.host).ok().flatten() })).collect::<Vec<_>>();
        for h in handles { if let Ok(v) = h.join() { out.push(v); } }
    }
    Ok(out)
}
#[tauri::command]
async fn ping_locations_batch(items: Vec<PingRequest>) -> Result<Vec<PingResult>, String> {
    tauri::async_runtime::spawn_blocking(move || ping_batch_blocking(items)).await.map_err(|e| e.to_string())?
}

fn helper_output(action: &str, args: &[&str]) -> Result<String, String> {
    let limit = match action { "disconnect" | "cancel-connect" => "20s", "engine-connect" => "170s", "connect" | "connect-saved" | "quick-connect" => "45s", _ => "30s" };
    let output = Command::new("timeout").args(["--signal=TERM", "--kill-after=3s", limit, "pkexec", HELPER, action]).args(args).output().map_err(|e| e.to_string())?;
    let mut text = String::from_utf8_lossy(&output.stdout).to_string(); text.push_str(&String::from_utf8_lossy(&output.stderr));
    if output.status.success() { Ok(text) }
    else if output.status.code() == Some(124) { Err(format!("{action} exceeded its safety deadline ({limit}); the worker was stopped without blocking the UI.\n{text}")) }
    else { Err(text) }
}
fn helper_json(action: &str, args: &[&str]) -> Result<Value, String> { let text = helper_output(action, args)?; serde_json::from_str(&text).map_err(|e| format!("Invalid backend JSON: {e}\n{text}")) }
fn state_value(path: &str, key: &str) -> Option<String> { fs::read_to_string(path).ok()?.lines().find_map(|l| { let (k, v) = l.split_once('=')?; (k == key).then(|| v.trim().to_string()) }) }
fn engine_value(key:&str)->Option<String>{ let raw=fs::read_to_string(ENGINE_STATE).ok()?; let v:Value=serde_json::from_str(&raw).ok()?; v.get(key).and_then(|x|x.as_str()).map(str::to_string) }
fn state_u64(path: &str, key: &str) -> u64 { state_value(path, key).and_then(|v| v.parse().ok()).unwrap_or(0) }
fn protected_route() -> bool {
    let tunnel_if=state_value(STATE,"TUNNEL_IF").unwrap_or_else(||"milmitxfrm0".into());
    Command::new("ip").args(["-4", "route", "get", "1.1.1.1"]).output().map(|o| o.status.success() && String::from_utf8_lossy(&o.stdout).contains(&tunnel_if)).unwrap_or(false)
}
fn tunnel_active() -> bool {
    let phase=engine_value("phase").unwrap_or_default();
    if phase=="CONNECTED" { return protected_route() || engine_value("protocol").as_deref()==Some("wireguard") || engine_value("protocol").as_deref()==Some("openvpn"); }
    let xfrm = fs::metadata("/sys/class/net/milmitxfrm0").is_ok(); let live = state_value(LIVE, "STATE").or_else(|| state_value(LIVE, "HEALTH")).unwrap_or_default().to_ascii_uppercase();
    xfrm && protected_route() && live != "DISCONNECTED" && live != "UNPROTECTED"
}

fn connect_location_blocking(id: String, generation: u64) -> Result<String, String> {
    let loc = parse_locations().into_iter().find(|x| x.id == id).ok_or_else(|| "unknown location".to_string())?;
    let candidates = candidate_ips(&loc.host);
    if candidates.is_empty() { return Err(format!("No trusted direct-IP candidate is bundled for {}. Refresh the endpoint catalog first.", loc.city)); }
    let csv=candidates.join(","); attempt_add(&format!("ENGINE_V3 location={} city={} identity={} candidates={}",loc.id,loc.city,loc.host,csv));
    if CONNECT_GENERATION.load(Ordering::SeqCst) != generation { return Err("Connection attempt cancelled.".into()); }
    match helper_output("engine-connect", &[&loc.host,&csv]) {
        Ok(text)=>{
            if CONNECT_GENERATION.load(Ordering::SeqCst) != generation { return Err("Connection attempt cancelled.".into()); }
            let safe=sanitize_backend(&text); if !safe.trim().is_empty(){attempt_add(&safe);}
            if engine_value("phase").as_deref()==Some("CONNECTED") || tunnel_active(){
                let protocol=engine_value("protocol").unwrap_or_else(||"ikev2".into()); let endpoint=engine_value("endpoint").unwrap_or_default();
                attempt_add(&format!("CONNECTED protocol={} endpoint={}",protocol,endpoint));
                Ok(format!("LOCATION={}\nCITY={}\nIDENTITY={}\nPROTOCOL={}\nENDPOINT={}\n{}",loc.id,loc.city,loc.host,protocol,endpoint,text))
            }else{Err(format!("Connection engine returned without a verified tunnel.\n{}",safe))}
        }
        Err(e)=>{ let safe=sanitize_backend(&e); attempt_add(&format!("ENGINE_V3_FAIL\n{}",safe)); Err(safe) }
    }
}
#[tauri::command]
async fn connect_location(id: String) -> Result<String, String> {
    let generation = CONNECT_GENERATION.fetch_add(1, Ordering::SeqCst) + 1; attempt_clear();
    tauri::async_runtime::spawn_blocking(move || connect_location_blocking(id, generation)).await.map_err(|e| e.to_string())?
}
#[tauri::command]
async fn cancel_connect() -> Result<String, String> {
    CONNECT_GENERATION.fetch_add(1, Ordering::SeqCst); attempt_add("CANCEL requested by user");
    tauri::async_runtime::spawn_blocking(|| helper_output("cancel-connect", &[])).await.map_err(|e| e.to_string())?
}

#[tauri::command]
fn connection_state() -> ConnectionState {
    let connected = tunnel_active(); let engine_phase=engine_value("phase");
    let raw_state = engine_phase.or_else(|| state_value(LIVE, "STATE")).or_else(|| state_value(LIVE, "HEALTH"));
    let state = if connected { raw_state.filter(|s| !s.eq_ignore_ascii_case("DISCONNECTED") && !s.eq_ignore_ascii_case("UNPROTECTED")).unwrap_or_else(|| "CONNECTED".into()) }
        else { raw_state.filter(|s| matches!(s.as_str(),"PREPARING"|"IKE"|"AUTHENTICATING"|"TUNNEL_ESTABLISHED"|"VERIFYING_DATA"|"FALLBACK"|"BLOCKED"|"FAILED"|"CANCELLING")).unwrap_or_else(||"DISCONNECTED".into()) };
    ConnectionState { connected, state,
        public_ip: if connected { state_value(STATE, "PUBLIC_IP").or_else(|| state_value(LIVE, "PUBLIC_IP")) } else { None },
        exit_country: if connected { state_value(STATE, "EXIT_COUNTRY").or_else(|| state_value(LIVE, "EXIT_COUNTRY")) } else { None },
        latency_ms: if connected { state_value(LIVE, "LATENCY_MS").and_then(|v| v.parse().ok()) } else { None }, }
}
fn read_u64(path: &str) -> u64 { fs::read_to_string(path).ok().and_then(|v| v.trim().parse::<u64>().ok()).unwrap_or(0) }
#[tauri::command]
fn traffic_snapshot() -> TrafficSnapshot {
    let connected = tunnel_active(); let iface=state_value(STATE,"TUNNEL_IF").unwrap_or_else(||"milmitxfrm0".into());
    let rxp=format!("/sys/class/net/{iface}/statistics/rx_bytes"); let txp=format!("/sys/class/net/{iface}/statistics/tx_bytes");
    TrafficSnapshot { connected, rx_bytes: if connected { read_u64(&rxp) } else { 0 }, tx_bytes: if connected { read_u64(&txp) } else { 0 },
        rx_bps: state_u64(LIVE, "RX_BPS"), tx_bps: state_u64(LIVE, "TX_BPS"), all_rx_bytes: state_u64(USAGE, "ALL_RX_BYTES"), all_tx_bytes: state_u64(USAGE, "ALL_TX_BYTES"),
        day_rx_bytes: state_u64(USAGE, "DAY_RX_BYTES"), day_tx_bytes: state_u64(USAGE, "DAY_TX_BYTES"), month_rx_bytes: state_u64(USAGE, "MONTH_RX_BYTES"), month_tx_bytes: state_u64(USAGE, "MONTH_TX_BYTES") }
}
#[tauri::command]
async fn ping_report(kind: String, host: Option<String>) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let target = match kind.as_str() { "internet" => "1.1.1.1".to_string(), "location" | "vpn" => { let h = host.ok_or_else(|| "location hostname required".to_string())?; ping_target(&h) }, _ => return Err("invalid ping report kind".into()) };
        let output = Command::new("ping").args(["-n", "-c", "8", "-W", "2", &target]).output().map_err(|e| e.to_string())?;
        let mut raw = String::from_utf8_lossy(&output.stdout).to_string(); raw.push_str(&String::from_utf8_lossy(&output.stderr));
        let loss = raw.lines().find(|l| l.contains("packet loss")).unwrap_or("Packet loss unavailable"); let stats = raw.lines().find(|l| l.contains("min/avg/max") || l.contains("round-trip")).unwrap_or("RTT/jitter unavailable");
        Ok(format!("Target: {target}\n{loss}\n{stats}\n\n{raw}"))
    }).await.map_err(|e| e.to_string())?
}

fn save_credentials_blocking(username: String, password: String) -> Result<String, String> {
    if username.is_empty() || username.len() > 128 || username.contains('\n') || username.contains('\r') {
        return Err("Invalid Surfshark service username.".into());
    }
    if password.is_empty() || password.len() > 512 || password.contains('\n') || password.contains('\r') {
        return Err("Invalid or empty Surfshark service password.".into());
    }
    let mut child = Command::new("timeout")
        .args(["--signal=TERM", "--kill-after=3s", "30s", "pkexec", HELPER, "credentials-save", &username])
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped())
        .spawn().map_err(|e| e.to_string())?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(password.as_bytes()).map_err(|e| e.to_string())?;
        stdin.write_all(b"\n").map_err(|e| e.to_string())?;
    }
    let output = child.wait_with_output().map_err(|e| e.to_string())?;
    let mut text = String::from_utf8_lossy(&output.stdout).to_string();
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    if output.status.success() { Ok(text) }
    else if output.status.code() == Some(124) { Err("Saving credentials exceeded its safety deadline.".into()) }
    else { Err(text) }
}
#[tauri::command]
async fn save_credentials(username: String, password: String) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || save_credentials_blocking(username, password)).await.map_err(|e| e.to_string())?
}
#[tauri::command]
async fn helper_action(action: String, args: Vec<String>) -> Result<String, String> {
    if !ALLOWED.contains(&action.as_str()) { return Err(format!("unsupported helper action: {action}")); }
    if action == "credentials-save" { return Err("Use the secure save_credentials command so the password is sent over stdin.".into()); }
    tauri::async_runtime::spawn_blocking(move || { let refs = args.iter().map(String::as_str).collect::<Vec<_>>(); helper_output(&action, &refs) }).await.map_err(|e| e.to_string())?
}
#[tauri::command]
async fn router_state() -> Result<Value, String> { tauri::async_runtime::spawn_blocking(|| helper_json("router-status", &[])).await.map_err(|e| e.to_string())? }
#[tauri::command]
async fn desktop_feature_state() -> Result<Value, String> { tauri::async_runtime::spawn_blocking(|| helper_json("desktop-status", &[])).await.map_err(|e| e.to_string())? }

fn desktop_dirs() -> Vec<PathBuf> { let mut v = Vec::new(); if let Ok(home) = std::env::var("HOME") { v.push(PathBuf::from(home).join(".local/share/applications")); } v.push(PathBuf::from("/usr/local/share/applications")); v.push(PathBuf::from("/usr/share/applications")); v }
fn desktop_value(text: &str, key: &str) -> Option<String> { text.lines().find_map(|l| l.strip_prefix(&(key.to_string() + "=")).map(|v| v.trim().to_string())) }
#[tauri::command]
fn list_desktop_apps() -> Vec<DesktopApp> {
    let mut out = Vec::new(); let mut seen = HashSet::new();
    for dir in desktop_dirs() { let Ok(rd) = fs::read_dir(dir) else { continue; }; for ent in rd.flatten() {
        let path = ent.path(); if path.extension().and_then(|x| x.to_str()) != Some("desktop") { continue; }
        let id = path.file_name().and_then(|x| x.to_str()).unwrap_or("").to_string(); if id.is_empty() || seen.contains(&id) { continue; }
        let Ok(text) = fs::read_to_string(&path) else { continue; };
        if desktop_value(&text, "NoDisplay").as_deref() == Some("true") || desktop_value(&text, "Hidden").as_deref() == Some("true") { continue; }
        let Some(name) = desktop_value(&text, "Name") else { continue; }; let Some(exec) = desktop_value(&text, "Exec") else { continue; }; let icon = desktop_value(&text, "Icon").unwrap_or_default();
        seen.insert(id.clone()); out.push(DesktopApp { id, name, icon, exec });
    }}
    out.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase())); out
}
fn user_config_dir() -> PathBuf { PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".into())).join(".config/milmit-secure") }
fn lists_path() -> PathBuf { user_config_dir().join("location-lists.json") }
#[tauri::command]
fn get_location_lists() -> Value { fs::read_to_string(lists_path()).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_else(|| serde_json::json!([])) }
#[tauri::command]
fn save_location_lists(lists: Value) -> Result<(), String> { if !lists.is_array() { return Err("location lists must be an array".into()); } let raw = serde_json::to_string_pretty(&lists).map_err(|e| e.to_string())?; if raw.len() > 131072 { return Err("location lists are too large".into()); } let dir = user_config_dir(); fs::create_dir_all(&dir).map_err(|e| e.to_string())?; fs::write(lists_path(), raw).map_err(|e| e.to_string()) }
fn autostart_path() -> PathBuf { PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".into())).join(".config/autostart/milmit-secure.desktop") }
#[tauri::command]
fn launch_at_startup_enabled() -> bool { autostart_path().exists() }
#[tauri::command]
fn set_launch_at_startup(enabled: bool) -> Result<(), String> {
    let path = autostart_path(); if !enabled { if path.exists() { fs::remove_file(path).map_err(|e| e.to_string())?; } return Ok(()); }
    let exe = std::env::current_exe().map_err(|e| e.to_string())?; if let Some(parent) = path.parent() { fs::create_dir_all(parent).map_err(|e| e.to_string())?; }
    let repo_root = exe.parent().and_then(|p| p.parent()).and_then(|p| p.parent()).map(PathBuf::from); let dev_launcher = repo_root.as_ref().map(|r| r.join("scripts/run-tauri-gui.sh"));
    let exec_line = if let Some(script) = dev_launcher.filter(|p| p.exists()) { format!("/bin/bash \"{}\"", script.display()) } else { format!("\"{}\"", exe.display()) };
    let content = format!("[Desktop Entry]\nType=Application\nName=MilMit Secure\nExec={exec_line}\nX-GNOME-Autostart-enabled=true\nNoDisplay=true\n"); fs::write(path, content).map_err(|e| e.to_string())
}

fn main() {
    tauri::Builder::default().setup(|app| Ok(runtime::setup(app)?)).invoke_handler(tauri::generate_handler![
        helper_action, save_credentials, list_locations, ping_location, ping_locations_batch, connect_location, cancel_connect,
        connection_attempt_log, connection_state, traffic_snapshot, ping_report, router_state,
        desktop_feature_state, list_desktop_apps, get_location_lists, save_location_lists,
        launch_at_startup_enabled, set_launch_at_startup, network_diagnostics::network_diagnostics
    ]).run(tauri::generate_context!()).expect("error while running MilMit Secure")
}