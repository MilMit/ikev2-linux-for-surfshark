use serde_json::Value;
use std::collections::BTreeSet;
use std::fs;
use std::io::Write;
use std::net::{IpAddr, ToSocketAddrs};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Instant;
use surfshark_ikev2_core::platform::{
    PlatformAdapter, PlatformConnectionStatus, PlatformDiagnostics, PlatformStatus, VpnProtocol,
};
use surfshark_ikev2_core::Location;

const HELPER: &str = "/usr/libexec/milmit-surfshark-helper";
const PLATFORM_HELPER: &str = "/usr/libexec/milmit-vpn-platform-helper";
const PROTOCOL_CONNECTOR: &str = "/usr/lib/milmit-surfshark/protocol-connect-v1.py";
const ENGINE_STATE: &str = "/run/milmit-surfshark/engine-v3.json";
const LIVE_STATE: &str = "/run/milmit-surfshark/live.state";
const CREDENTIALS: &str = "/etc/milmit-surfshark/credentials";
const WG_DIR: &str = "/etc/milmit-surfshark/wireguard";
const OVPN_DIR: &str = "/etc/milmit-surfshark/openvpn";

#[derive(Debug, Default, Clone)]
pub struct LinuxPlatformAdapter;

impl LinuxPlatformAdapter {
    pub fn new() -> Self { Self }

    fn privileged(&self, helper: &str, action: &str, args: &[&str], timeout: &str) -> Result<String, String> {
        if !Path::new(helper).is_file() { return Err(format!("privileged helper is not installed at {helper}")); }
        let output = Command::new("timeout")
            .args(["--signal=TERM", "--kill-after=3s", timeout, "pkexec", helper, action])
            .args(args)
            .output()
            .map_err(|e| format!("failed to launch privileged helper: {e}"))?;
        let mut text = String::from_utf8_lossy(&output.stdout).to_string();
        text.push_str(&String::from_utf8_lossy(&output.stderr));
        if output.status.success() { Ok(text) }
        else if output.status.code() == Some(124) { Err(format!("{action} exceeded its safety deadline ({timeout})")) }
        else { Err(text.trim().to_string()) }
    }

    fn helper(&self, action: &str, args: &[&str], timeout: &str) -> Result<String, String> {
        self.privileged(HELPER, action, args, timeout)
    }

    fn platform_helper(&self, action: &str, args: &[&str]) -> Result<Value, String> {
        let text = self.privileged(PLATFORM_HELPER, action, args, "30s")?;
        serde_json::from_str(text.trim()).map_err(|e| format!("invalid platform helper response: {e}"))
    }

    fn save_credentials_root(&self, username: &str, password: &str) -> Result<(), String> {
        if username.is_empty() || username.len() > 128 || username.contains('\n') || username.contains('\r') { return Err("invalid service username".into()); }
        if password.is_empty() || password.len() > 512 || password.contains('\n') || password.contains('\r') { return Err("invalid service password".into()); }
        let mut child = Command::new("pkexec")
            .args([HELPER, "credentials-save", username])
            .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped())
            .spawn().map_err(|e| format!("failed to launch credential helper: {e}"))?;
        if let Some(mut stdin) = child.stdin.take() {
            stdin.write_all(password.as_bytes()).map_err(|e| e.to_string())?;
            stdin.write_all(b"\n").map_err(|e| e.to_string())?;
        }
        let output = child.wait_with_output().map_err(|e| e.to_string())?;
        if output.status.success() { Ok(()) } else {
            let mut text = String::from_utf8_lossy(&output.stdout).to_string();
            text.push_str(&String::from_utf8_lossy(&output.stderr));
            Err(text.trim().to_string())
        }
    }

    fn candidates(&self, location: &Location) -> Result<Vec<String>, String> {
        let mut out = BTreeSet::new();
        for ip in &location.endpoint.fallback_ips { if matches!(ip, IpAddr::V4(_)) { out.insert(ip.to_string()); } }
        if out.is_empty() {
            let target = format!("{}:{}", location.endpoint.hostname, location.endpoint.ike_port);
            if let Ok(addrs) = target.to_socket_addrs() {
                for addr in addrs { if addr.ip().is_ipv4() { out.insert(addr.ip().to_string()); } }
            }
        }
        if out.is_empty() { return Err("no IPv4 endpoint is available; ship fallback IPs in the bundled catalog for restricted networks".into()); }
        Ok(out.into_iter().take(32).collect())
    }

    fn parse_engine_status(&self) -> PlatformStatus {
        let raw = fs::read_to_string(ENGINE_STATE).unwrap_or_default();
        let value: Value = serde_json::from_str(&raw).unwrap_or(Value::Null);
        let phase = value.get("phase").and_then(Value::as_str).unwrap_or("DISCONNECTED").to_ascii_uppercase();
        let status = match phase.as_str() {
            "PREPARING" | "DISCOVERING" | "IKE" | "AUTHENTICATING" | "TUNNEL_ESTABLISHED" | "VERIFYING_DATA" | "FALLBACK" => PlatformConnectionStatus::Connecting,
            "CONNECTED" => PlatformConnectionStatus::Connected,
            "DISCONNECTING" | "CANCELLING" => PlatformConnectionStatus::Disconnecting,
            "FAILED" | "BLOCKED" | "ERROR" => PlatformConnectionStatus::Error,
            _ => PlatformConnectionStatus::Disconnected,
        };
        let endpoint = value.get("endpoint").and_then(Value::as_str).map(str::to_owned);
        let protocol = value.get("protocol").and_then(Value::as_str).map(str::to_owned);
        let message = value.get("message").and_then(Value::as_str).map(str::to_owned);
        let public_ip = fs::read_to_string(LIVE_STATE).ok().and_then(|raw| raw.lines().find_map(|line| line.strip_prefix("PUBLIC_IP=").map(str::to_owned)));
        PlatformStatus { status, protocol, endpoint, public_ip, message }
    }

    fn profile_exists(dir: &str, identity: &str, ext: &str) -> bool { Path::new(dir).join(format!("{identity}.{ext}")).is_file() }

    fn spawn_engine_connect(&self, identity: String, candidates: String) -> Result<(), String> {
        if !Path::new(HELPER).is_file() { return Err(format!("privileged helper is not installed at {HELPER}")); }
        std::thread::spawn(move || {
            let mut cmd = Command::new("timeout");
            cmd.args(["--signal=TERM", "--kill-after=3s", "170s", "pkexec", HELPER, "engine-connect"]).arg(identity).arg(candidates);
            let _ = cmd.output();
        });
        Ok(())
    }

    fn spawn_forced_protocol(&self, protocol: &str, identity: &str) -> Result<(), String> {
        if !Path::new(PROTOCOL_CONNECTOR).is_file() { return Err(format!("forced protocol connector is not installed at {PROTOCOL_CONNECTOR}")); }
        let protocol = protocol.to_string(); let identity = identity.to_string();
        std::thread::spawn(move || {
            let mut cmd = Command::new("timeout");
            cmd.args(["--signal=TERM", "--kill-after=3s", "90s", "pkexec", "/usr/bin/python3", PROTOCOL_CONNECTOR]).arg(protocol).arg(identity);
            let _ = cmd.output();
        });
        Ok(())
    }

    fn probe_target(&self, target: &str) -> Result<Option<u32>, String> {
        if !Path::new("/usr/bin/ike-scan").is_file() && !Path::new("/usr/sbin/ike-scan").is_file() { return Ok(None); }
        let started = Instant::now();
        let output = Command::new("ike-scan").args(["--ikev2", "--sport=0", "--retry=1", "--timeout=1200", "--nodns", "--quiet", target]).output().map_err(|e| format!("ike-scan unavailable: {e}"))?;
        let elapsed = started.elapsed().as_millis().min(u32::MAX as u128) as u32;
        let mut text = String::from_utf8_lossy(&output.stdout).to_string(); text.push_str(&String::from_utf8_lossy(&output.stderr));
        let responded = text.lines().any(|line| line.trim_start().starts_with(target));
        Ok(responded.then_some(elapsed.max(1)))
    }
}

impl PlatformAdapter for LinuxPlatformAdapter {
    fn connect(&self, location: &Location, protocol: VpnProtocol) -> Result<PlatformStatus, String> {
        if !Path::new(CREDENTIALS).is_file() { return Err("Surfshark manual service credentials are not saved yet".into()); }
        let identity = location.endpoint.hostname.as_str();
        match protocol {
            VpnProtocol::Auto | VpnProtocol::Ikev2 => { let candidates = self.candidates(location)?.join(","); self.spawn_engine_connect(identity.to_string(), candidates)?; }
            VpnProtocol::WireGuard => { if !Self::profile_exists(WG_DIR, identity, "conf") { return Err(format!("WireGuard profile is missing for {identity}")); } self.spawn_forced_protocol("wireguard", identity)?; }
            VpnProtocol::OpenVpn => { if !Self::profile_exists(OVPN_DIR, identity, "ovpn") { return Err(format!("OpenVPN profile is missing for {identity}")); } self.spawn_forced_protocol("openvpn", identity)?; }
        }
        Ok(PlatformStatus { status: PlatformConnectionStatus::Connecting, protocol: Some(match protocol { VpnProtocol::Auto => "auto", VpnProtocol::Ikev2 => "ikev2", VpnProtocol::WireGuard => "wireguard", VpnProtocol::OpenVpn => "openvpn" }.into()), endpoint: None, public_ip: None, message: Some("Connection worker started".into()) })
    }

    fn disconnect(&self) -> Result<PlatformStatus, String> { self.helper("disconnect", &[], "20s")?; Ok(self.parse_engine_status()) }
    fn status(&self) -> Result<PlatformStatus, String> { Ok(self.parse_engine_status()) }
    fn set_kill_switch(&self, enabled: bool) -> Result<(), String> { let flag=if enabled{"1"}else{"0"}; self.helper("lockdown", &[flag], "30s")?; self.helper("lockdown-apply", &[], "30s")?; Ok(()) }
    fn set_dns_protection(&self, enabled: bool) -> Result<(), String> { let flag=if enabled{"1"}else{"0"}; self.platform_helper("dns-set", &[flag]).map(|_| ()) }
    fn set_ipv6_protection(&self, enabled: bool) -> Result<(), String> { let flag=if enabled{"1"}else{"0"}; self.platform_helper("ipv6-set", &[flag]).map(|_| ()) }
    fn credentials_status(&self) -> Result<bool, String> { if !Path::new(HELPER).is_file(){return Ok(false)}; let text=self.helper("credentials-status", &[], "15s")?; Ok(text.lines().any(|line| line.trim()=="SAVED=1")) }
    fn save_credentials(&self, username: &str, password: &str) -> Result<(), String> { self.save_credentials_root(username,password) }
    fn probe_latency(&self, location: &Location) -> Result<Option<u32>, String> {
        let candidates=self.candidates(location)?; let mut best=None;
        for target in candidates.into_iter().take(6) { if let Some(ms)=self.probe_target(&target)? { best=Some(best.map_or(ms, |current:u32| current.min(ms))); } }
        Ok(best)
    }
    fn split_tunnel_status(&self) -> Result<Value, String> { self.platform_helper("split-status", &[]) }
    fn set_split_tunnel_enabled(&self, enabled: bool) -> Result<Value, String> { let flag=if enabled{"1"}else{"0"}; self.platform_helper("split-enable", &[flag]) }
    fn add_split_tunnel_rule(&self, target: &str, mode: &str) -> Result<Value, String> { self.platform_helper("split-add", &[target,mode]) }
    fn remove_split_tunnel_rule(&self, target: &str) -> Result<Value, String> { self.platform_helper("split-remove", &[target]) }
    fn diagnostics(&self) -> Result<PlatformDiagnostics, String> {
        let helper_available=Path::new(HELPER).is_file(); let platform_helper_available=Path::new(PLATFORM_HELPER).is_file();
        let engine_status=if helper_available { self.helper("engine-status", &[], "30s").ok().and_then(|text| serde_json::from_str::<Value>(&text).ok()) } else { None };
        let split=if platform_helper_available { self.split_tunnel_status().ok() } else { None };
        Ok(PlatformDiagnostics { adapter:"linux-helper-v3".into(), available:cfg!(target_os="linux"), helper_available, credentials_available:Path::new(CREDENTIALS).is_file(), ikev2_available:Path::new("/usr/sbin/swanctl").is_file()||Path::new("/usr/bin/swanctl").is_file(), wireguard_available:Path::new("/usr/bin/wg").is_file()||Path::new("/usr/bin/wg-quick").is_file(), openvpn_available:Path::new("/usr/sbin/openvpn").is_file()||Path::new("/usr/bin/openvpn").is_file(), kill_switch_supported:helper_available, dns_protection_supported:platform_helper_available, split_tunnel_supported:platform_helper_available, details:serde_json::json!({"engine_state":self.parse_engine_status(),"engine":engine_status,"helper":HELPER,"platform_helper":PLATFORM_HELPER,"forced_protocol_connector":PROTOCOL_CONNECTOR,"wireguard_profiles":WG_DIR,"openvpn_profiles":OVPN_DIR,"split_tunnel":split}) })
    }
}
