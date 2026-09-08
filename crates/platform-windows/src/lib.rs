use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use surfshark_ikev2_core::platform::{PlatformAdapter, PlatformConnectionStatus, PlatformDiagnostics, PlatformStatus, VpnProtocol};
use surfshark_ikev2_core::Location;

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

    fn require_admin_error(context: &str, error: String) -> String {
        format!("{context} failed. This operation must be executed by MilMitVpnService/administrator: {error}")
    }

    fn state_path() -> PathBuf { Self::program_data().join("windows-policy.json") }

    fn load_policy_state() -> serde_json::Value {
        fs::read_to_string(Self::state_path()).ok()
            .and_then(|v| serde_json::from_str(&v).ok())
            .unwrap_or_else(|| serde_json::json!({"dns":false,"split_enabled":false,"rules":[]}))
    }

    fn save_policy_state(state: &serde_json::Value) -> Result<(), String> {
        fs::create_dir_all(Self::program_data()).map_err(|e| e.to_string())?;
        let tmp = Self::state_path().with_extension("json.tmp");
        fs::write(&tmp, serde_json::to_vec_pretty(state).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
        fs::rename(tmp, Self::state_path()).map_err(|e| e.to_string())
    }

    fn vpn_profile_exists(name: &str) -> bool {
        let escaped = name.replace('\'', "''");
        Self::powershell(&format!("if (Get-VpnConnection -Name '{escaped}' -ErrorAction SilentlyContinue) {{ exit 0 }} else {{ exit 1 }}")).is_ok()
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

    fn managed_profile_script(body: &str) -> String {
        format!("$profiles=Get-VpnConnection -ErrorAction SilentlyContinue | Where-Object {{$_.Name -like 'MilMit *'}}; foreach($p in $profiles){{ $n=$p.Name; {body} }}")
    }
}

impl PlatformAdapter for WindowsPlatformAdapter {
    fn connect(&self, location: &Location, protocol: VpnProtocol) -> Result<PlatformStatus, String> {
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

    fn set_kill_switch(&self, _enabled: bool) -> Result<(), String> {
        Err("Windows kill switch remains fail-closed until the WFP provider is installed in MilMitVpnService".into())
    }

    fn set_dns_protection(&self, enabled: bool) -> Result<(), String> {
        let script = if enabled {
            "$old=Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object {$_.Comment -eq 'MilMit VPN DNS'}; $old | Remove-DnsClientNrptRule -Force -ErrorAction SilentlyContinue; Add-DnsClientNrptRule -Namespace '.' -NameServers @('162.252.172.57','149.154.159.92') -Comment 'MilMit VPN DNS' | Out-Null"
        } else {
            "Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object {$_.Comment -eq 'MilMit VPN DNS'} | Remove-DnsClientNrptRule -Force -ErrorAction Stop"
        };
        Self::powershell(script).map_err(|e| Self::require_admin_error("NRPT DNS policy", e))?;
        let mut state = Self::load_policy_state();
        state["dns"] = serde_json::Value::Bool(enabled);
        Self::save_policy_state(&state)
    }

    fn set_ipv6_protection(&self, _enabled: bool) -> Result<(), String> {
        Err("Windows IPv6 protection is intentionally not implemented by disabling ms_tcpip6 globally; it requires the WFP/service route policy".into())
    }

    fn credentials_status(&self) -> Result<bool, String> { Ok(false) }
    fn save_credentials(&self, _username: &str, _password: &str) -> Result<(), String> { Err("Use Windows Credential Manager/native VPN profile provisioning".into()) }

    fn probe_latency(&self, location: &Location) -> Result<Option<u32>, String> {
        let host = location.endpoint.hostname.replace('\'', "''");
        let text = Self::powershell(&format!("$r=Test-NetConnection -ComputerName '{host}' -Port 443 -WarningAction SilentlyContinue; if ($r.TcpTestSucceeded) {{ [int]$r.PingReplyDetails.RoundtripTime }}"))?;
        Ok(text.lines().last().and_then(|v| v.trim().parse::<u32>().ok()))
    }

    fn split_tunnel_status(&self) -> Result<serde_json::Value, String> {
        Ok(Self::load_policy_state())
    }

    fn set_split_tunnel_enabled(&self, enabled: bool) -> Result<serde_json::Value, String> {
        let value = if enabled { "$true" } else { "$false" };
        Self::powershell(&Self::managed_profile_script(&format!("Set-VpnConnection -Name $n -SplitTunneling {value} -Force -ErrorAction Stop | Out-Null")))
            .map_err(|e| Self::require_admin_error("Windows VPN split-tunnel policy", e))?;
        let mut state = Self::load_policy_state();
        state["split_enabled"] = serde_json::Value::Bool(enabled);
        Self::save_policy_state(&state)?;
        Ok(state)
    }

    fn add_split_tunnel_rule(&self, target: &str, mode: &str) -> Result<serde_json::Value, String> {
        if mode != "vpn" { return Err("Windows bypass-CIDR requires physical-uplink resolution in MilMitVpnService and remains fail-closed".into()); }
        let target = target.trim();
        if target.is_empty() || target.contains('\'') || target.contains('"') || target.contains(';') { return Err("invalid_split_target".into()); }
        let body = format!("Add-VpnConnectionRoute -ConnectionName $n -DestinationPrefix '{target}' -PassThru -ErrorAction Stop | Out-Null");
        Self::powershell(&Self::managed_profile_script(&body)).map_err(|e| Self::require_admin_error("Windows VPN route", e))?;
        let mut state = Self::load_policy_state();
        let mut rules = state.get("rules").and_then(|v| v.as_array()).cloned().unwrap_or_default();
        if !rules.iter().any(|r| r.get("target").and_then(|v| v.as_str()) == Some(target)) {
            rules.push(serde_json::json!({"target":target,"mode":"vpn"}));
        }
        state["rules"] = serde_json::Value::Array(rules);
        Self::save_policy_state(&state)?;
        Ok(state)
    }

    fn remove_split_tunnel_rule(&self, target: &str) -> Result<serde_json::Value, String> {
        let target = target.trim();
        if target.is_empty() || target.contains('\'') || target.contains('"') || target.contains(';') { return Err("invalid_split_target".into()); }
        let body = format!("Remove-VpnConnectionRoute -ConnectionName $n -DestinationPrefix '{target}' -PassThru -ErrorAction SilentlyContinue | Out-Null");
        Self::powershell(&Self::managed_profile_script(&body)).map_err(|e| Self::require_admin_error("Windows VPN route removal", e))?;
        let mut state = Self::load_policy_state();
        let rules = state.get("rules").and_then(|v| v.as_array()).cloned().unwrap_or_default().into_iter()
            .filter(|r| r.get("target").and_then(|v| v.as_str()) != Some(target)).collect();
        state["rules"] = serde_json::Value::Array(rules);
        Self::save_policy_state(&state)?;
        Ok(state)
    }

    fn diagnostics(&self) -> Result<PlatformDiagnostics, String> {
        Ok(PlatformDiagnostics { adapter: "windows-native-v2".into(), available: cfg!(target_os = "windows"), helper_available: Self::powershell("if (Get-Service MilMitVpnService -ErrorAction SilentlyContinue) { 'yes' }").map(|v| v.contains("yes")).unwrap_or(false), credentials_available: false, ikev2_available: true, wireguard_available: Self::wireguard_exe().is_some(), openvpn_available: Self::openvpn_exe().is_some(), kill_switch_supported: false, dns_protection_supported: true, split_tunnel_supported: true, details: serde_json::json!({"program_data":Self::program_data(),"native_vpn":"rasdial/Get-VpnConnection","dns":"NRPT","split_tunnel":"Windows VPN connection routes (vpn mode)","bypass_mode":"pending service physical-uplink resolver","kill_switch":"pending WFP provider","credential_policy":"Windows Credential Manager/native profile only"}) })
    }
}
