use serde::{Deserialize, Serialize};
use std::fs;
use std::process::Command;
use std::thread;
use std::time::Duration;

#[path = "../../../../crates/gui/src/bundled_endpoints.rs"]
mod bundled_endpoints;

const HELPER: &str = "/usr/libexec/milmit-surfshark-helper";
const LOCATION_SOURCE: &str = include_str!("../../../../crates/gui/src/locations.rs");
const STATE: &str = "/run/milmit-surfshark/restricted.state";
const LIVE: &str = "/run/milmit-surfshark/live.state";
const ALLOWED: &[&str] = &[
    "status","connect","quick-connect","connect-saved","disconnect","watchdog-status","router-status","hotspot-status","hotspot-repair",
    "rules-status","rules-update","health","apply-safe","full-live-test","speed-test",
    "dns-test","mtu-test","save-lkg","support-bundle","emergency-stop","candidates",
    "route-explain","route-test","policy-add","policy-remove","router-options","device-set",
    "guest-start","guest-stop","guest-status","credentials-status","credentials-save"
];

#[derive(Clone, Serialize)]
struct UiLocation { id: String, country: String, city: String, host: String }

#[derive(Clone, Serialize)]
struct ConnectionState {
    connected: bool,
    state: String,
    public_ip: Option<String>,
    exit_country: Option<String>,
    latency_ms: Option<u32>,
}

#[derive(Clone, Deserialize)]
struct PingRequest { id: String, host: String }

#[derive(Clone, Serialize)]
struct PingResult { id: String, ping: Option<u32> }

fn quoted_field(line: &str, field: &str) -> Option<String> {
    let marker = format!("{field}: \"");
    let start = line.find(&marker)? + marker.len();
    let rest = &line[start..];
    let end = rest.find('"')?;
    Some(rest[..end].to_string())
}

fn parse_locations() -> Vec<UiLocation> {
    LOCATION_SOURCE.lines().filter(|line| line.trim_start().starts_with("Location {")).filter_map(|line| {
        Some(UiLocation { id: quoted_field(line,"id")?, country: quoted_field(line,"country")?, city: quoted_field(line,"city")?, host: quoted_field(line,"host")? })
    }).collect()
}

#[tauri::command]
fn list_locations() -> Vec<UiLocation> { parse_locations() }

fn valid_host(host: &str) -> bool {
    host.len() <= 255 && host.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-'))
}

fn ping_target(host: &str) -> String {
    if host == "ee-tll.prod.surfshark.com" { return "185.174.159.123".into(); }
    bundled_endpoints::for_host(host).first().copied().unwrap_or(host).to_string()
}

fn ping_once(target: &str) -> Result<Option<u32>, String> {
    let output = Command::new("ping").args(["-n","-c","1","-W","1",target]).output().map_err(|e|e.to_string())?;
    if !output.status.success() { return Ok(None); }
    let text=String::from_utf8_lossy(&output.stdout); let Some(pos)=text.find("time=") else{return Ok(None)}; let rest=&text[pos+5..];
    let end=rest.find(|c:char|c==' '||c=='\n').unwrap_or(rest.len()); Ok(rest[..end].parse::<f64>().ok().map(|v|v.round() as u32))
}

#[tauri::command]
fn ping_location(host:String)->Result<Option<u32>,String>{
    if !valid_host(&host){return Err("invalid location hostname".into())}
    ping_once(&ping_target(&host))
}

// A single IPC call handles many location pings, with a small fixed worker
// width. This avoids launching 100+ concurrent Tauri invokes and keeps the UI
// responsive while country/header latency is populated in the background.
#[tauri::command]
fn ping_locations_batch(items: Vec<PingRequest>) -> Result<Vec<PingResult>, String> {
    if items.len() > 256 { return Err("too many ping targets".into()); }
    if items.iter().any(|x| x.id.len() > 64 || !valid_host(&x.host)) { return Err("invalid ping target".into()); }
    let mut out = Vec::with_capacity(items.len());
    for chunk in items.chunks(6) {
        let handles = chunk.iter().cloned().map(|item| {
            thread::spawn(move || PingResult { id: item.id, ping: ping_once(&ping_target(&item.host)).ok().flatten() })
        }).collect::<Vec<_>>();
        for h in handles { if let Ok(v) = h.join() { out.push(v); } }
    }
    Ok(out)
}

fn helper_output(action:&str,args:&[&str])->Result<String,String>{
    let output=Command::new("pkexec").arg(HELPER).arg(action).args(args).output().map_err(|e|e.to_string())?;
    let mut text=String::from_utf8_lossy(&output.stdout).to_string(); text.push_str(&String::from_utf8_lossy(&output.stderr));
    if output.status.success(){Ok(text)}else{Err(text)}
}

#[tauri::command]
fn connect_location(id:String)->Result<String,String>{
    let loc=parse_locations().into_iter().find(|x|x.id==id).ok_or_else(||"unknown location".to_string())?;
    let mut candidates=Vec::<String>::new();
    if loc.host=="ee-tll.prod.surfshark.com"{candidates.push("185.174.159.123".into());}
    for ip in bundled_endpoints::for_host(&loc.host){ if !candidates.iter().any(|x|x==ip){candidates.push((*ip).into());} }
    if candidates.is_empty(){return Err(format!("No trusted direct-IP candidate is bundled for {}. Refresh the endpoint catalog first.",loc.city));}
    let mut failures=String::new();
    for ip in candidates {
        match helper_output("connect-saved", &[&ip,&loc.host]) {
            Ok(text)=>{
                // Verify the connector actually committed the requested server identity.
                // This prevents the UI from claiming Germany/Tallinn/etc. while a stale
                // quick-connect profile is active underneath.
                let mut matched = false;
                for _ in 0..8 {
                    if state_value(STATE,"SERVER_IDENTITY").as_deref() == Some(loc.host.as_str()) { matched = true; break; }
                    thread::sleep(Duration::from_millis(150));
                }
                if !matched {
                    let actual = state_value(STATE,"SERVER_IDENTITY").unwrap_or_else(||"unknown".into());
                    return Err(format!("Tunnel came up but selected-location verification failed. Requested {}, active identity {}.", loc.host, actual));
                }
                return Ok(format!("LOCATION={}\nCITY={}\nIDENTITY={}\nENDPOINT={}\n{}",loc.id,loc.city,loc.host,ip,text));
            },
            Err(e)=>{failures.push_str(&format!("\n[{ip}] {e}\n"));}
        }
    }
    Err(format!("All direct-IP candidates failed for {}.{}",loc.city,failures))
}

fn state_value(path:&str,key:&str)->Option<String>{
    fs::read_to_string(path).ok()?.lines().find_map(|l|{let(k,v)=l.split_once('=')?;(k==key).then(||v.trim().to_string())})
}

#[tauri::command]
fn connection_state()->ConnectionState{
    let xfrm=Command::new("ip").args(["link","show","milmitxfrm0"]).output().map(|o|o.status.success()).unwrap_or(false);
    let state=state_value(LIVE,"STATE").or_else(||state_value(LIVE,"HEALTH")).unwrap_or_else(||if xfrm{"CONNECTED".into()}else{"DISCONNECTED".into()});
    ConnectionState{connected:xfrm,state,public_ip:state_value(STATE,"PUBLIC_IP").or_else(||state_value(LIVE,"PUBLIC_IP")),exit_country:state_value(STATE,"EXIT_COUNTRY").or_else(||state_value(LIVE,"EXIT_COUNTRY")),latency_ms:state_value(LIVE,"LATENCY_MS").and_then(|v|v.parse().ok())}
}

#[tauri::command]
fn ping_report(kind:String,host:Option<String>)->Result<String,String>{
    let target=match kind.as_str(){"internet"=>"1.1.1.1".to_string(),"location"|"vpn"=>{let h=host.ok_or_else(||"location hostname required".to_string())?;ping_target(&h)},_=>return Err("invalid ping report kind".into())};
    let output=Command::new("ping").args(["-n","-c","8","-W","2",&target]).output().map_err(|e|e.to_string())?;
    let mut raw=String::from_utf8_lossy(&output.stdout).to_string();raw.push_str(&String::from_utf8_lossy(&output.stderr));
    let loss=raw.lines().find(|l|l.contains("packet loss")).unwrap_or("Packet loss unavailable");
    let stats=raw.lines().find(|l|l.contains("min/avg/max")||l.contains("round-trip")).unwrap_or("RTT/jitter unavailable");
    Ok(format!("Target: {target}\n{loss}\n{stats}\n\n{raw}"))
}

#[tauri::command]
fn helper_action(action:String,args:Vec<String>)->Result<String,String>{
    if !ALLOWED.contains(&action.as_str()){return Err(format!("unsupported helper action: {action}"));}
    let refs=args.iter().map(String::as_str).collect::<Vec<_>>(); helper_output(&action,&refs)
}

fn main(){
    tauri::Builder::default().invoke_handler(tauri::generate_handler![helper_action,list_locations,ping_location,ping_locations_batch,connect_location,connection_state,ping_report]).run(tauri::generate_context!()).expect("error while running MilMit Secure");
}
