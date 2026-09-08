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
    fn diagnostics(&self) -> Result<PlatformDiagnostics, String>;
}
