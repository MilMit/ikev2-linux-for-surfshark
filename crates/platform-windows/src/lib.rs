use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;
use surfshark_ikev2_core::platform::{
    PlatformAdapter, PlatformConnectionStatus, PlatformDiagnostics, PlatformStatus, VpnProtocol,
};
use surfshark_ikev2_core::Location;

#[derive(Debug, Default, Clone)]
pub struct WindowsPlatformAdapter;

impl WindowsPlatformAdapter {
    pub fn new() -> Self { Self }

    fn program_data() -> PathBuf {
        env::var_os("PROGRAMDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(r"C:\ProgramData"))
            .join("MilMit")
            .join("VPN")
    }

    fn profile_name(location: &Location) -> String {
        format!("MilMit {}", location.id)
    }

    fn powershell(script: &str) -> Result<String, String> {
        let output = Command::new("powershell.exe")
            .args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script])
            .output()
            .map_err(|e| format!("failed to launch PowerShell: {e}"))?;
        let mut text = String::from_utf8_lossy(&output.stdout).to_string();
        text.push_str(&String::from_utf8_lossy(&output.stderr));
        if output.status.success() { Ok(text.trim().to_string()) } else { Err(text.trim().to_string()) }
    }

    fn vpn_profile_exists(name: &str) -> bool {
        let escaped = name.replace('\'', "''");
        Self::powershell(&format!("if (Get-VpnConnection -Name '{escaped}' -ErrorAction SilentlyContinue) {{ exit 0 }} else {{ exit 1 }}")).is_ok()
    }

    fn connect_ikev2(location: &Location) -> Result<(), String> {
        let name = Self::profile_name(location);
        if !Self::vpn_profile_exists(&name) {
            return Err(format!("Windows IKEv2 profile '{name}' is not installed. Provision the native VPN profile first."));
        }
        let output = Command::new("rasdial.exe")
            .arg(&name)
            .output()
            .map_err(|e| format!("failed to launch rasdial: {e}"))?;
        if output.status.success() { Ok(()) } else {
            let mut text = String::from_utf8_lossy(&output.stdout).to_string();
            text.push_str(&String::from_utf8_lossy(&output.stderr));
            Err(text.trim().to_string())
        }
    }

    fn wireguard_exe() -> Option<PathBuf> {
        [
            PathBuf::from(r"C:\Program Files\WireGuard\wireguard.exe"),
            PathBuf::from(r"C:\Program Files (x86)\WireGuard\wireguard.exe"),
        ].into_iter().find(|p| p.is_file())
    }

    fn openvpn_exe() -> Option<PathBuf> {
        [
            PathBuf::from(r"C:\Program Files\OpenVPN\bin\openvpn.exe"),
            PathBuf::from(r"C:\Program Files\OpenVPN Connect\OpenVPNConnect.exe"),
        ].into_iter().find(|p| p.is_file())
    }

    fn connect_wireguard(location: &Location) -> Result<(), String> {
        let exe = Self::wireguard_exe().ok_or_else(|| "WireGuard for Windows is not installed".to_string())?;
        let conf = Self::program_data().join("wireguard").join(format!("{}.conf", location.endpoint.hostname));
        if !conf.is_file() { return Err(format!("WireGuard profile is missing: {}", conf.display())); }
        let output = Command::new(exe).arg("/installtunnelservice").arg(&conf).output().map_err(|e| e.to_string())?;
        if output.status.success() { Ok(()) } else { Err(String::from_utf8_lossy(&output.stderr).trim().to_string()) }
    }

    fn connect_openvpn(location: &Location) -> Result<(), String> {
        let exe = Self::openvpn_exe().ok_or_else(|| "OpenVPN is not installed".to_string())?;
        let conf = Self::program_data().join("openvpn").join(format!("{}.ovpn", location.endpoint.hostname));
        if !conf.is_file() { return Err(format!("OpenVPN profile is missing: {}", conf.display())); }
        let output = Command::new(exe).args(["--config"]).arg(conf).args(["--daemon"]).output().map_err(|e| e.to_string())?;
        if output.status.success() { Ok(()) } else { Err(String::from_utf8_lossy(&output.stderr).trim().to_string()) }
    }

    fn ras_status() -> PlatformStatus {
        let output = Command::new("rasdial.exe").output();
        match output {
            Ok(out) => {
                let text = String::from_utf8_lossy(&out.stdout).to_string();
                let connected = !text.to_ascii_lowercase().contains("no connections");
                PlatformStatus {
                    status: if connected { PlatformConnectionStatus::Connected } else { PlatformConnectionStatus::Disconnected },
                    protocol: connected.then(|| "ikev2".into()),
                    endpoint: None,
                    public_ip: None,
                    message: Some(text.trim().to_string()),
                }
            }
            Err(e) => PlatformStatus { status: PlatformConnectionStatus::Error, message: Some(e.to_string()), ..Default::default() },
        }
    }

    fn command_exists(program: &str) -> bool {
        Command::new("where.exe").arg(program).output().map(|o| o.status.success()).unwrap_or(false)
    }
}

impl PlatformAdapter for WindowsPlatformAdapter {
    fn connect(&self, location: &Location, protocol: VpnProtocol) -> Result<PlatformStatus, String> {
        match protocol {
            VpnProtocol::Auto | VpnProtocol::Ikev2 => Self::connect_ikev2(location)?,
            VpnProtocol::WireGuard => Self::connect_wireguard(location)?,
            VpnProtocol::OpenVpn => Self::connect_openvpn(location)?,
        }
        Ok(PlatformStatus {
            status: PlatformConnectionStatus::Connecting,
            protocol: Some(match protocol { VpnProtocol::Auto => "ikev2", VpnProtocol::Ikev2 => "ikev2", VpnProtocol::WireGuard => "wireguard", VpnProtocol::OpenVpn => "openvpn" }.into()),
            endpoint: Some(location.endpoint.hostname.clone()),
            public_ip: None,
            message: Some("Windows native connection command accepted".into()),
        })
    }

    fn disconnect(&self) -> Result<PlatformStatus, String> {
        let _ = Command::new("rasdial.exe").arg("/disconnect").output();
        if let Some(wg) = Self::wireguard_exe() {
            if let Ok(entries) = std::fs::read_dir(Self::program_data().join("wireguard")) {
                for entry in entries.flatten() {
                    if let Some(stem) = entry.path().file_stem().and_then(|s| s.to_str()) {
                        let _ = Command::new(&wg).arg("/uninstalltunnelservice").arg(stem).output();
                    }
                }
            }
        }
        Ok(PlatformStatus::default())
    }

    fn status(&self) -> Result<PlatformStatus, String> { Ok(Self::ras_status()) }

    fn set_kill_switch(&self, enabled: bool) -> Result<(), String> {
        let rule = "MilMit VPN Kill Switch";
        let script = if enabled {
            format!("if (-not (Get-NetFirewallRule -DisplayName '{rule}' -ErrorAction SilentlyContinue)) {{ New-NetFirewallRule -DisplayName '{rule}' -Direction Outbound -Action Block -Profile Any | Out-Null }}")
        } else {
            format!("Get-NetFirewallRule -DisplayName '{rule}' -ErrorAction SilentlyContinue | Remove-NetFirewallRule")
        };
        Self::powershell(&script).map(|_| ())
    }

    fn set_dns_protection(&self, _enabled: bool) -> Result<(), String> {
        Err("Windows DNS protection requires the platform service/NRPT adapter and is not enabled yet".into())
    }

    fn set_ipv6_protection(&self, _enabled: bool) -> Result<(), String> {
        Err("Windows IPv6 protection requires the platform service adapter and is not enabled yet".into())
    }

    fn credentials_status(&self) -> Result<bool, String> {
        Ok(Self::vpn_profile_exists("MilMit"))
    }

    fn save_credentials(&self, _username: &str, _password: &str) -> Result<(), String> {
        Err("Credentials are intentionally not stored by the Rust Windows adapter; use Windows Credential Manager/native VPN profile provisioning".into())
    }

    fn probe_latency(&self, location: &Location) -> Result<Option<u32>, String> {
        let script = format!("$r=Test-NetConnection -ComputerName '{}' -Port 443 -WarningAction SilentlyContinue; if ($r.TcpTestSucceeded) {{ [int]$r.PingReplyDetails.RoundtripTime }}", location.endpoint.hostname.replace('\'', "''"));
        let text = Self::powershell(&script)?;
        Ok(text.lines().last().and_then(|v| v.trim().parse::<u32>().ok()))
    }

    fn diagnostics(&self) -> Result<PlatformDiagnostics, String> {
        Ok(PlatformDiagnostics {
            adapter: "windows-native-v1".into(),
            available: cfg!(target_os = "windows"),
            helper_available: true,
            credentials_available: false,
            ikev2_available: Self::command_exists("rasdial.exe"),
            wireguard_available: Self::wireguard_exe().is_some(),
            openvpn_available: Self::openvpn_exe().is_some(),
            kill_switch_supported: true,
            dns_protection_supported: false,
            split_tunnel_supported: false,
            details: serde_json::json!({
                "program_data": Self::program_data(),
                "native_vpn": "rasdial/Get-VpnConnection",
                "credential_policy": "Windows Credential Manager/native profile only",
            }),
        })
    }
}
