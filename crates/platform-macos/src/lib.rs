use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;
use surfshark_ikev2_core::platform::{
    PlatformAdapter, PlatformConnectionStatus, PlatformDiagnostics, PlatformStatus, VpnProtocol,
};
use surfshark_ikev2_core::Location;

#[derive(Debug, Default, Clone)]
pub struct MacOsPlatformAdapter;

impl MacOsPlatformAdapter {
    pub fn new() -> Self { Self }

    fn support_root() -> PathBuf {
        env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/Users/Shared"))
            .join("Library")
            .join("Application Support")
            .join("MilMitVPN")
    }

    fn service_name(location: &Location) -> String {
        format!("MilMit {}", location.id)
    }

    fn scutil_nc(args: &[&str]) -> Result<String, String> {
        let output = Command::new("/usr/sbin/scutil")
            .arg("--nc")
            .args(args)
            .output()
            .map_err(|e| format!("failed to run scutil: {e}"))?;
        let mut text = String::from_utf8_lossy(&output.stdout).to_string();
        text.push_str(&String::from_utf8_lossy(&output.stderr));
        if output.status.success() { Ok(text.trim().to_string()) } else { Err(text.trim().to_string()) }
    }

    fn service_exists(name: &str) -> bool {
        Self::scutil_nc(&["list"]).map(|text| text.lines().any(|line| line.contains(name))).unwrap_or(false)
    }

    fn connect_ikev2(location: &Location) -> Result<(), String> {
        let name = Self::service_name(location);
        if !Self::service_exists(&name) {
            return Err(format!("macOS IKEv2 Network Service '{name}' is not provisioned. Create/provision the native service before connecting."));
        }
        Self::scutil_nc(&["start", &name]).map(|_| ())
    }

    fn disconnect_all_managed() {
        if let Ok(list) = Self::scutil_nc(&["list"]) {
            for line in list.lines().filter(|line| line.contains("MilMit ")) {
                if let Some(start) = line.rfind('"') {
                    let left = &line[..start];
                    if let Some(prev) = left.rfind('"') {
                        let name = &line[prev + 1..start];
                        let _ = Self::scutil_nc(&["stop", name]);
                    }
                }
            }
        }
    }

    fn status_any() -> PlatformStatus {
        let list = match Self::scutil_nc(&["list"]) {
            Ok(v) => v,
            Err(e) => return PlatformStatus { status: PlatformConnectionStatus::Error, message: Some(e), ..Default::default() },
        };
        for line in list.lines().filter(|line| line.contains("MilMit ")) {
            if line.contains("Connected") {
                return PlatformStatus {
                    status: PlatformConnectionStatus::Connected,
                    protocol: Some("ikev2".into()),
                    endpoint: None,
                    public_ip: None,
                    message: Some(line.trim().to_string()),
                };
            }
            if line.contains("Connecting") {
                return PlatformStatus {
                    status: PlatformConnectionStatus::Connecting,
                    protocol: Some("ikev2".into()),
                    endpoint: None,
                    public_ip: None,
                    message: Some(line.trim().to_string()),
                };
            }
        }
        PlatformStatus::default()
    }

    fn wireguard_available() -> bool {
        Path::new("/usr/local/bin/wg-quick").is_file() || Path::new("/opt/homebrew/bin/wg-quick").is_file()
    }

    fn openvpn_available() -> bool {
        Path::new("/usr/local/sbin/openvpn").is_file() || Path::new("/opt/homebrew/sbin/openvpn").is_file()
    }
}

impl PlatformAdapter for MacOsPlatformAdapter {
    fn connect(&self, location: &Location, protocol: VpnProtocol) -> Result<PlatformStatus, String> {
        match protocol {
            VpnProtocol::Auto | VpnProtocol::Ikev2 => Self::connect_ikev2(location)?,
            VpnProtocol::WireGuard => {
                return Err("macOS WireGuard connection requires a signed Network Extension/helper integration; raw wg-quick is intentionally not launched from the GUI".into())
            }
            VpnProtocol::OpenVpn => {
                return Err("macOS OpenVPN connection requires a signed helper/service integration; raw privileged OpenVPN is intentionally not launched from the GUI".into())
            }
        }
        Ok(PlatformStatus {
            status: PlatformConnectionStatus::Connecting,
            protocol: Some("ikev2".into()),
            endpoint: Some(location.endpoint.hostname.clone()),
            public_ip: None,
            message: Some("macOS native Network Service start requested".into()),
        })
    }

    fn disconnect(&self) -> Result<PlatformStatus, String> {
        Self::disconnect_all_managed();
        Ok(PlatformStatus::default())
    }

    fn status(&self) -> Result<PlatformStatus, String> { Ok(Self::status_any()) }

    fn set_kill_switch(&self, _enabled: bool) -> Result<(), String> {
        Err("macOS kill switch requires a signed Network Extension/content filter or privileged helper and is not enabled yet".into())
    }

    fn set_dns_protection(&self, _enabled: bool) -> Result<(), String> {
        Err("macOS DNS protection requires Network Extension DNS settings and is not enabled yet".into())
    }

    fn set_ipv6_protection(&self, _enabled: bool) -> Result<(), String> {
        Err("macOS IPv6 protection requires Network Extension route policy and is not enabled yet".into())
    }

    fn credentials_status(&self) -> Result<bool, String> {
        Ok(Self::scutil_nc(&["list"]).map(|v| v.contains("MilMit ")).unwrap_or(false))
    }

    fn save_credentials(&self, _username: &str, _password: &str) -> Result<(), String> {
        Err("Credentials are intentionally not stored by the Rust macOS adapter; use Keychain/native Network Service provisioning".into())
    }

    fn probe_latency(&self, location: &Location) -> Result<Option<u32>, String> {
        let started = Instant::now();
        let output = Command::new("/usr/bin/nc")
            .args(["-G", "2", "-z", &location.endpoint.hostname, "443"])
            .output()
            .map_err(|e| format!("nc probe failed: {e}"))?;
        if output.status.success() {
            Ok(Some(started.elapsed().as_millis().min(u32::MAX as u128) as u32))
        } else {
            Ok(None)
        }
    }

    fn diagnostics(&self) -> Result<PlatformDiagnostics, String> {
        Ok(PlatformDiagnostics {
            adapter: "macos-native-v1".into(),
            available: cfg!(target_os = "macos"),
            helper_available: false,
            credentials_available: Self::scutil_nc(&["list"]).map(|v| v.contains("MilMit ")).unwrap_or(false),
            ikev2_available: Path::new("/usr/sbin/scutil").is_file(),
            wireguard_available: Self::wireguard_available(),
            openvpn_available: Self::openvpn_available(),
            kill_switch_supported: false,
            dns_protection_supported: false,
            split_tunnel_supported: false,
            details: serde_json::json!({
                "support_root": Self::support_root(),
                "native_vpn": "scutil --nc / Network Service",
                "credential_policy": "Keychain/native service only",
                "network_extension_required_for_full_feature_set": true,
            }),
        })
    }
}
