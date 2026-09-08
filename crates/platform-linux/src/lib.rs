use serde_json::Value;
use std::collections::BTreeSet;
use std::fs;
use std::net::{IpAddr, ToSocketAddrs};
use std::path::Path;
use std::process::Command;
use surfshark_ikev2_core::platform::{
    PlatformAdapter, PlatformConnectionStatus, PlatformDiagnostics, PlatformStatus, VpnProtocol,
};
use surfshark_ikev2_core::Location;

const HELPER: &str = "/usr/libexec/milmit-surfshark-helper";
const ENGINE_STATE: &str = "/run/milmit-surfshark/engine-v3.json";
const LIVE_STATE: &str = "/run/milmit-surfshark/live.state";
const CREDENTIALS: &str = "/etc/milmit-surfshark/credentials";
const WG_DIR: &str = "/etc/milmit-surfshark/wireguard";
const OVPN_DIR: &str = "/etc/milmit-surfshark/openvpn";

#[derive(Debug, Default, Clone)]
pub struct LinuxPlatformAdapter;

impl LinuxPlatformAdapter {
    pub fn new() -> Self {
        Self
    }

    fn helper(&self, action: &str, args: &[&str], timeout: &str) -> Result<String, String> {
        if !Path::new(HELPER).is_file() {
            return Err(format!("privileged helper is not installed at {HELPER}"));
        }
        let output = Command::new("timeout")
            .args(["--signal=TERM", "--kill-after=3s", timeout, "pkexec", HELPER, action])
            .args(args)
            .output()
            .map_err(|e| format!("failed to launch privileged helper: {e}"))?;
        let mut text = String::from_utf8_lossy(&output.stdout).to_string();
        text.push_str(&String::from_utf8_lossy(&output.stderr));
        if output.status.success() {
            Ok(text)
        } else if output.status.code() == Some(124) {
            Err(format!("{action} exceeded its safety deadline ({timeout})"))
        } else {
            Err(text.trim().to_string())
        }
    }

    fn candidates(&self, location: &Location) -> Result<Vec<String>, String> {
        let mut out = BTreeSet::new();
        for ip in &location.endpoint.fallback_ips {
            if matches!(ip, IpAddr::V4(_)) {
                out.insert(ip.to_string());
            }
        }
        if out.is_empty() {
            let target = format!("{}:{}", location.endpoint.hostname, location.endpoint.ike_port);
            if let Ok(addrs) = target.to_socket_addrs() {
                for addr in addrs {
                    if addr.ip().is_ipv4() {
                        out.insert(addr.ip().to_string());
                    }
                }
            }
        }
        if out.is_empty() {
            return Err("no IPv4 endpoint is available; ship fallback IPs in the bundled catalog for restricted networks".into());
        }
        Ok(out.into_iter().take(32).collect())
    }

    fn parse_engine_status(&self) -> PlatformStatus {
        let raw = fs::read_to_string(ENGINE_STATE).unwrap_or_default();
        let value: Value = serde_json::from_str(&raw).unwrap_or(Value::Null);
        let phase = value
            .get("phase")
            .and_then(Value::as_str)
            .unwrap_or("DISCONNECTED")
            .to_ascii_uppercase();
        let status = match phase.as_str() {
            "PREPARING" | "IKE" | "AUTHENTICATING" | "TUNNEL_ESTABLISHED" | "VERIFYING_DATA" | "FALLBACK" => PlatformConnectionStatus::Connecting,
            "CONNECTED" => PlatformConnectionStatus::Connected,
            "DISCONNECTING" => PlatformConnectionStatus::Disconnecting,
            "FAILED" | "BLOCKED" | "ERROR" => PlatformConnectionStatus::Error,
            _ => PlatformConnectionStatus::Disconnected,
        };
        let endpoint = value.get("endpoint").and_then(Value::as_str).map(str::to_owned);
        let protocol = value.get("protocol").and_then(Value::as_str).map(str::to_owned);
        let message = value.get("message").and_then(Value::as_str).map(str::to_owned);
        let public_ip = fs::read_to_string(LIVE_STATE).ok().and_then(|raw| {
            raw.lines().find_map(|line| line.strip_prefix("PUBLIC_IP=").map(str::to_owned))
        });
        PlatformStatus { status, protocol, endpoint, public_ip, message }
    }

    fn profile_exists(dir: &str, identity: &str, ext: &str) -> bool {
        Path::new(dir).join(format!("{identity}.{ext}")).is_file()
    }
}

impl PlatformAdapter for LinuxPlatformAdapter {
    fn connect(&self, location: &Location, protocol: VpnProtocol) -> Result<PlatformStatus, String> {
        if !Path::new(CREDENTIALS).is_file() {
            return Err("Surfshark manual service credentials are not saved yet".into());
        }
        let identity = location.endpoint.hostname.as_str();
        match protocol {
            VpnProtocol::Auto | VpnProtocol::Ikev2 => {
                let candidates = self.candidates(location)?.join(",");
                self.helper("engine-connect", &[identity, &candidates], "170s")?;
            }
            VpnProtocol::WireGuard => {
                if !Self::profile_exists(WG_DIR, identity, "conf") {
                    return Err(format!("WireGuard profile is missing for {identity}"));
                }
                return Err("explicit WireGuard selection is not exposed by the installed helper yet; Auto can use WireGuard fallback when the profile exists".into());
            }
            VpnProtocol::OpenVpn => {
                if !Self::profile_exists(OVPN_DIR, identity, "ovpn") {
                    return Err(format!("OpenVPN profile is missing for {identity}"));
                }
                return Err("explicit OpenVPN selection is not exposed by the installed helper yet; Auto can use OpenVPN fallback when the profile exists".into());
            }
        }
        Ok(self.parse_engine_status())
    }

    fn disconnect(&self) -> Result<PlatformStatus, String> {
        self.helper("disconnect", &[], "20s")?;
        Ok(self.parse_engine_status())
    }

    fn status(&self) -> Result<PlatformStatus, String> {
        Ok(self.parse_engine_status())
    }

    fn set_kill_switch(&self, enabled: bool) -> Result<(), String> {
        let flag = if enabled { "1" } else { "0" };
        self.helper("lockdown", &[flag], "30s")?;
        self.helper("lockdown-apply", &[], "30s")?;
        Ok(())
    }

    fn diagnostics(&self) -> Result<PlatformDiagnostics, String> {
        let helper_available = Path::new(HELPER).is_file();
        let engine_status = if helper_available {
            self.helper("engine-status", &[], "30s").ok().and_then(|text| serde_json::from_str::<Value>(&text).ok())
        } else {
            None
        };
        Ok(PlatformDiagnostics {
            adapter: "linux-helper-v1".into(),
            available: cfg!(target_os = "linux"),
            helper_available,
            credentials_available: Path::new(CREDENTIALS).is_file(),
            ikev2_available: Path::new("/usr/sbin/swanctl").is_file() || Path::new("/usr/bin/swanctl").is_file(),
            wireguard_available: Path::new("/usr/bin/wg").is_file() || Path::new("/usr/bin/wg-quick").is_file(),
            openvpn_available: Path::new("/usr/sbin/openvpn").is_file() || Path::new("/usr/bin/openvpn").is_file(),
            kill_switch_supported: helper_available,
            dns_protection_supported: helper_available,
            split_tunnel_supported: helper_available,
            details: serde_json::json!({
                "engine_state": self.parse_engine_status(),
                "engine": engine_status,
                "helper": HELPER,
                "wireguard_profiles": WG_DIR,
                "openvpn_profiles": OVPN_DIR
            }),
        })
    }
}
