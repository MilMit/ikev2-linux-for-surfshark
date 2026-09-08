use std::env;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;
use surfshark_ikev2_core::platform::{PlatformAdapter, PlatformConnectionStatus, PlatformDiagnostics, PlatformStatus, VpnProtocol};
use surfshark_ikev2_core::Location;

const SERVICE_IPC: &str = "127.0.0.1:47631";

#[derive(Debug, Default, Clone)]
pub struct WindowsPlatformAdapter;

impl WindowsPlatformAdapter {
    pub fn new() -> Self { Self }

    fn program_data() -> PathBuf {
        env::var_os("PROGRAMDATA").map(PathBuf::from).unwrap_or_else(|| PathBuf::from(r"C:\ProgramData"))
            .join("MilMit").join("VPN")
    }

    fn profile_name(location: &Location) -> String { format!("MilMit {}", location.id) }

    fn powershell(script: &str) -> Result<String, String> {
        let output = Command::new("powershell.exe")
            .args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script])
            .output().map_err(|e| format!("failed to launch PowerShell: {e}"))?;
        let mut text = String::from_utf8_lossy(&output.stdout).to_string();
        text.push_str(&String::from_utf8_lossy(&output.stderr));
        if output.status.success() { Ok(text.trim().to_string()) } else { Err(text.trim().to_string()) }
    }

    fn state_path() -> PathBuf { Self::program_data().join("windows-policy.json") }

    fn load_policy_state() -> serde_json::Value {
        fs::read_to_string(Self::state_path()).ok()
            .and_then(|v| serde_json::from_str(&v).ok())
            .unwrap_or_else(|| serde_json::json!({"dns":false,"kill_switch":false,"split_enabled":false,"rules":[]}))
    }

    fn save_policy_state(state: &serde_json::Value) -> Result<(), String> {
        fs::create_dir_all(Self::program_data()).map_err(|e| e.to_string())?;
        let tmp = Self::state_path().with_extension("json.tmp");
        fs::write(&tmp, serde_json::to_vec_pretty(state).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
        fs::rename(tmp, Self::state_path()).map_err(|e| e.to_string())
    }

    fn vpn_profile_exists(name: &str) -> bool {
        let escaped = name.replace('\'', "''");
        Self::powershell(&format!("if ((Get-VpnConnection -Name '{escaped}' -ErrorAction SilentlyContinue) -or (Get-VpnConnection -AllUserConnection -Name '{escaped}' -ErrorAction SilentlyContinue)) {{ exit 0 }} else {{ exit 1 }}")).is_ok()
    }

    fn connect_ikev2(location: &Location) -> Result<(), String> {
        let name = Self::profile_name(location);
        if !Self::vpn_profile_exists(&name) { return Err(format!("Windows IKEv2 profile '{name}' is not installed")); }
        let out = Command::new("rasdial.exe").arg(&name).output().map_err(|e| e.to_string())?;
        if out.status.success() { Ok(()) } else { Err(String::from_utf8_lossy(&out.stderr).trim().to_string()) }
    }

    fn wireguard_exe() -> Option<PathBuf> {
        [PathBuf::from(r"C:\Program Files\WireGuard\wireguard.exe"), PathBuf::from(r"C:\Program Files (x86)\WireGuard\wireguard.exe")]
            .into_iter().find(|p| p.is_file())
    }

    fn openvpn_exe() -> Option<PathBuf> {
        [PathBuf::from(r"C:\Program Files\OpenVPN\bin\openvpn.exe"), PathBuf::from(r"C:\Program Files\OpenVPN Connect\OpenVPNConnect.exe")]
            .into_iter().find(|p| p.is_file())
    }

    fn connect_wireguard(location: &Location) -> Result<(), String> {
        let exe = Self::wireguard_exe().ok_or_else(|| "WireGuard for Windows is not installed".to_string())?;
        let conf = Self::program_data().join("wireguard").join(format!("{}.conf", location.endpoint.hostname));
        if !conf.is_file() { return Err(format!("WireGuard profile is missing: {}", conf.display())); }
        let out = Command::new(exe).arg("/installtunnelservice").arg(conf).output().map_err(|e| e.to_string())?;
        if out.status.success() { Ok(()) } else { Err(String::from_utf8_lossy(&out.stderr).trim().to_string()) }
    }

    fn connect_openvpn(location: &Location) -> Result<(), String> {
        let exe = Self::openvpn_exe().ok_or_else(|| "OpenVPN is not installed".to_string())?;
        let conf = Self::program_data().join("openvpn").join(format!("{}.ovpn", location.endpoint.hostname));
        if !conf.is_file() { return Err(format!("OpenVPN profile is missing: {}", conf.display())); }
        let out = Command::new(exe).arg("--config").arg(conf).output().map_err(|e| e.to_string())?;
        if out.status.success() { Ok(()) } else { Err(String::from_utf8_lossy(&out.stderr).trim().to_string()) }
    }

    fn ras_status() -> PlatformStatus {
        match Command::new("rasdial.exe").output() {
            Ok(out) => {
                let text = String::from_utf8_lossy(&out.stdout).to_string();
                let connected = !text.to_ascii_lowercase().contains("no connections");
                PlatformStatus { status: if connected { PlatformConnectionStatus::Connected } else { PlatformConnectionStatus::Disconnected }, protocol: connected.then(|| "ikev2".into()), endpoint: None, public_ip: None, message: Some(text.trim().to_string()) }
            }
            Err(e) => PlatformStatus { status: PlatformConnectionStatus::Error, message: Some(e.to_string()), ..Default::default() },
        }
    }

    fn resolve_endpoint_ip(location: &Location) -> Result<String, String> {
        if let Some(ip) = location.endpoint.fallback_ips.first() { return Ok(ip.to_string()); }
        (location.endpoint.hostname.as_str(), 443).to_socket_addrs()
            .map_err(|e| format!("failed to resolve VPN endpoint: {e}"))?
            .next().map(|v| v.ip().to_string()).ok_or_else(|| "VPN endpoint resolved to no address".into())
    }

    fn physical_interface_index() -> Result<u32, String> {
        let text = Self::powershell("$r=Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric,InterfaceMetric | Select-Object -First 1 -ExpandProperty InterfaceIndex; [int]$r")?;
        text.lines().last().and_then(|v| v.trim().parse::<u32>().ok()).filter(|v| *v > 0)
            .ok_or_else(|| format!("could not determine physical interface index: {text}"))
    }

    fn remember_kill_switch_context(location: &Location) -> Result<(), String> {
        let mut state = Self::load_policy_state();
        state["endpoint_ip"] = serde_json::Value::String(Self::resolve_endpoint_ip(location)?);
        state["physical_interface_index"] = serde_json::Value::from(Self::physical_interface_index()?);
        Self::save_policy_state(&state)
    }

    fn service_call(payload: serde_json::Value) -> Result<serde_json::Value, String> {
        let addr = SERVICE_IPC.parse().map_err(|e| format!("invalid service IPC address: {e}"))?;
        let mut stream = TcpStream::connect_timeout(&addr, Duration::from_secs(2))
            .map_err(|e| format!("MilMitVpnService IPC unavailable: {e}"))?;
        stream.set_read_timeout(Some(Duration::from_secs(6))).map_err(|e| e.to_string())?;
        stream.set_write_timeout(Some(Duration::from_secs(4))).map_err(|e| e.to_string())?;
        let mut request = serde_json::to_vec(&payload).map_err(|e| e.to_string())?;
        request.push(b'\n');
        stream.write_all(&request).map_err(|e| format!("service IPC write failed: {e}"))?;
        stream.flush().map_err(|e| e.to_string())?;
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        reader.read_line(&mut line).map_err(|e| format!("service IPC read failed: {e}"))?;
        let response: serde_json::Value = serde_json::from_str(line.trim()).map_err(|e| format!("invalid service response: {e}"))?;
        if response.get("ok").and_then(|v| v.as_bool()) == Some(true) {
            Ok(response)
        } else {
            Err(response.get("error").and_then(|v| v.as_str()).unwrap_or("Windows service rejected request").to_string())
        }
    }

    fn service_available() -> bool {
        Self::service_call(serde_json::json!({"action":"ping"})).is_ok()
    }
}

impl PlatformAdapter for WindowsPlatformAdapter {
    fn connect(&self, location: &Location, protocol: VpnProtocol) -> Result<PlatformStatus, String> {
        let _ = Self::remember_kill_switch_context(location);
        match protocol {
            VpnProtocol::Auto | VpnProtocol::Ikev2 => Self::connect_ikev2(location)?,
            VpnProtocol::WireGuard => Self::connect_wireguard(location)?,
            VpnProtocol::OpenVpn => Self::connect_openvpn(location)?,
        }
        Ok(PlatformStatus { status: PlatformConnectionStatus::Connecting, protocol: Some(match protocol { VpnProtocol::Auto | VpnProtocol::Ikev2 => "ikev2", VpnProtocol::WireGuard => "wireguard", VpnProtocol::OpenVpn => "openvpn" }.into()), endpoint: Some(location.endpoint.hostname.clone()), public_ip: None, message: Some("Windows native connection command accepted".into()) })
    }

    fn disconnect(&self) -> Result<PlatformStatus, String> {
        let _ = Command::new("rasdial.exe").arg("/disconnect").output();
        Ok(PlatformStatus::default())
    }

    fn status(&self) -> Result<PlatformStatus, String> { Ok(Self::ras_status()) }

    fn set_kill_switch(&self, enabled: bool) -> Result<(), String> {
        let mut state = Self::load_policy_state();
        let payload = if enabled {
            let ifindex = state.get("physical_interface_index").and_then(|v| v.as_u64()).ok_or("kill-switch context has no physical interface index; connect/select a server first")?;
            let endpoint = state.get("endpoint_ip").and_then(|v| v.as_str()).ok_or("kill-switch context has no VPN endpoint IP; connect/select a server first")?;
            serde_json::json!({"action":"kill_switch","enabled":true,"interface_index":ifindex,"endpoint_ip":endpoint})
        } else {
            serde_json::json!({"action":"kill_switch","enabled":false})
        };
        Self::service_call(payload)?;
        state["kill_switch"] = serde_json::Value::Bool(enabled);
        Self::save_policy_state(&state)
    }

    fn set_dns_protection(&self, enabled: bool) -> Result<(), String> {
        Self::service_call(serde_json::json!({
            "action":"dns_protection",
            "enabled":enabled,
            "servers":["162.252.172.57","149.154.159.92"]
        }))?;
        let mut state = Self::load_policy_state();
        state["dns"] = serde_json::Value::Bool(enabled);
        Self::save_policy_state(&state)
    }

    fn set_ipv6_protection(&self, _enabled: bool) -> Result<(), String> {
        Err("Windows IPv6 leak protection is provided by the WFP physical-uplink kill switch; global ms_tcpip6 disable is intentionally not used".into())
    }

    fn credentials_status(&self) -> Result<bool, String> { Ok(false) }
    fn save_credentials(&self, _username: &str, _password: &str) -> Result<(), String> { Err("Use Windows Credential Manager/native VPN profile provisioning".into()) }

    fn probe_latency(&self, location: &Location) -> Result<Option<u32>, String> {
        let host = location.endpoint.hostname.replace('\'', "''");
        let text = Self::powershell(&format!("$r=Test-NetConnection -ComputerName '{host}' -Port 443 -WarningAction SilentlyContinue; if ($r.TcpTestSucceeded) {{ [int]$r.PingReplyDetails.RoundtripTime }}"))?;
        Ok(text.lines().last().and_then(|v| v.trim().parse::<u32>().ok()))
    }

    fn split_tunnel_status(&self) -> Result<serde_json::Value, String> { Ok(Self::load_policy_state()) }

    fn set_split_tunnel_enabled(&self, enabled: bool) -> Result<serde_json::Value, String> {
        Self::service_call(serde_json::json!({"action":"split_tunnel","enabled":enabled}))?;
        let mut state = Self::load_policy_state();
        state["split_enabled"] = serde_json::Value::Bool(enabled);
        Self::save_policy_state(&state)?;
        Ok(state)
    }

    fn add_split_tunnel_rule(&self, target: &str, mode: &str) -> Result<serde_json::Value, String> {
        if mode != "vpn" { return Err("Windows bypass-CIDR requires dedicated physical-uplink route resolution and remains fail-closed".into()); }
        let target = target.trim();
        Self::service_call(serde_json::json!({"action":"split_route_add","target":target}))?;
        let mut state = Self::load_policy_state();
        let mut rules = state.get("rules").and_then(|v| v.as_array()).cloned().unwrap_or_default();
        if !rules.iter().any(|r| r.get("target").and_then(|v| v.as_str()) == Some(target)) { rules.push(serde_json::json!({"target":target,"mode":"vpn"})); }
        state["rules"] = serde_json::Value::Array(rules);
        Self::save_policy_state(&state)?;
        Ok(state)
    }

    fn remove_split_tunnel_rule(&self, target: &str) -> Result<serde_json::Value, String> {
        let target = target.trim();
        Self::service_call(serde_json::json!({"action":"split_route_remove","target":target}))?;
        let mut state = Self::load_policy_state();
        let rules = state.get("rules").and_then(|v| v.as_array()).cloned().unwrap_or_default().into_iter().filter(|r| r.get("target").and_then(|v| v.as_str()) != Some(target)).collect();
        state["rules"] = serde_json::Value::Array(rules);
        Self::save_policy_state(&state)?;
        Ok(state)
    }

    fn diagnostics(&self) -> Result<PlatformDiagnostics, String> {
        let service_available = Self::service_available();
        Ok(PlatformDiagnostics {
            adapter: "windows-native-v5".into(),
            available: cfg!(target_os = "windows"),
            helper_available: service_available,
            credentials_available: false,
            ikev2_available: true,
            wireguard_available: Self::wireguard_exe().is_some(),
            openvpn_available: Self::openvpn_exe().is_some(),
            kill_switch_supported: service_available,
            dns_protection_supported: service_available,
            split_tunnel_supported: service_available,
            details: serde_json::json!({
                "program_data":Self::program_data(),
                "native_vpn":"rasdial/Get-VpnConnection",
                "privileged_networking":"MilMitVpnService LocalSystem",
                "kill_switch":"WFP ALE_AUTH_CONNECT V4/V6",
                "dns":"NRPT via service",
                "split_tunnel":"all-user Windows VPN connection routes via service (vpn mode)",
                "service_ipc":SERVICE_IPC,
                "bypass_mode":"pending hardened physical-uplink route resolver",
                "credential_policy":"Windows Credential Manager/native profile only",
                "profile_policy":"split-tunnel policy requires all-user MilMit VPN profiles"
            })
        })
    }
}
