use crate::Location;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum VpnProtocol {
    Auto,
    WireGuard,
    Ikev2,
    OpenVpn,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PlatformConnectionStatus {
    Disconnected,
    Connecting,
    Connected,
    Disconnecting,
    Error,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlatformStatus {
    pub status: PlatformConnectionStatus,
    pub protocol: Option<String>,
    pub endpoint: Option<String>,
    pub public_ip: Option<String>,
    pub message: Option<String>,
}

impl Default for PlatformStatus {
    fn default() -> Self {
        Self {
            status: PlatformConnectionStatus::Disconnected,
            protocol: None,
            endpoint: None,
            public_ip: None,
            message: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlatformDiagnostics {
    pub adapter: String,
    pub available: bool,
    pub helper_available: bool,
    pub credentials_available: bool,
    pub ikev2_available: bool,
    pub wireguard_available: bool,
    pub openvpn_available: bool,
    pub kill_switch_supported: bool,
    pub dns_protection_supported: bool,
    pub split_tunnel_supported: bool,
    pub details: serde_json::Value,
}

pub trait PlatformAdapter: Send + Sync {
    fn connect(&self, location: &Location, protocol: VpnProtocol) -> Result<PlatformStatus, String>;
    fn disconnect(&self) -> Result<PlatformStatus, String>;
    fn status(&self) -> Result<PlatformStatus, String>;
    fn set_kill_switch(&self, enabled: bool) -> Result<(), String>;
    fn set_dns_protection(&self, _enabled: bool) -> Result<(), String> { Ok(()) }
    fn set_ipv6_protection(&self, _enabled: bool) -> Result<(), String> { Ok(()) }
    fn credentials_status(&self) -> Result<bool, String>;
    fn save_credentials(&self, username: &str, password: &str) -> Result<(), String>;
    fn probe_latency(&self, location: &Location) -> Result<Option<u32>, String>;
    fn split_tunnel_status(&self) -> Result<serde_json::Value, String>;
    fn set_split_tunnel_enabled(&self, enabled: bool) -> Result<serde_json::Value, String>;
    fn add_split_tunnel_rule(&self, target: &str, mode: &str) -> Result<serde_json::Value, String>;
    fn remove_split_tunnel_rule(&self, target: &str) -> Result<serde_json::Value, String>;
    fn diagnostics(&self) -> Result<PlatformDiagnostics, String>;
}
