pub mod catalog;
pub mod health;
pub mod platform;

use serde::{Deserialize, Serialize};
use std::net::IpAddr;
use thiserror::Error;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Endpoint {
    pub hostname: String,
    #[serde(default)]
    pub fallback_ips: Vec<IpAddr>,
    pub ike_port: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Location {
    pub id: String,
    pub country: String,
    pub city: String,
    pub endpoint: Endpoint,
    pub certificate_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderManifest {
    pub id: String,
    pub display_name: String,
    #[serde(default)]
    pub locations: Vec<Location>,
}

impl ProviderManifest {
    pub fn location(&self, id: &str) -> Option<&Location> {
        self.locations.iter().find(|location| location.id == id)
    }
}

#[derive(Debug, Clone)]
pub struct ServiceCredentials {
    pub username: String,
    pub password: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConnectionPlan {
    pub provider_id: String,
    pub location_id: String,
    pub remote_hostname: String,
    pub fallback_ips: Vec<IpAddr>,
    pub remote_port: u16,
    pub certificate_id: String,
    pub eap_identity: String,
}

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("service username is empty")]
    EmptyUsername,
    #[error("service password is empty")]
    EmptyPassword,
    #[error("provider id is empty")]
    EmptyProvider,
    #[error("location hostname is empty")]
    EmptyHostname,
    #[error("unsupported IKE port: {0}")]
    UnsupportedPort(u16),
    #[error("unknown location: {0}")]
    UnknownLocation(String),
}

pub fn build_plan(
    provider_id: &str,
    credentials: &ServiceCredentials,
    location: &Location,
) -> Result<ConnectionPlan, CoreError> {
    if provider_id.trim().is_empty() {
        return Err(CoreError::EmptyProvider);
    }
    if credentials.username.trim().is_empty() {
        return Err(CoreError::EmptyUsername);
    }
    if credentials.password.is_empty() {
        return Err(CoreError::EmptyPassword);
    }
    if location.endpoint.hostname.trim().is_empty() {
        return Err(CoreError::EmptyHostname);
    }
    if !matches!(location.endpoint.ike_port, 500 | 4500) {
        return Err(CoreError::UnsupportedPort(location.endpoint.ike_port));
    }

    Ok(ConnectionPlan {
        provider_id: provider_id.to_owned(),
        location_id: location.id.clone(),
        remote_hostname: location.endpoint.hostname.clone(),
        fallback_ips: location.endpoint.fallback_ips.clone(),
        remote_port: location.endpoint.ike_port,
        certificate_id: location.certificate_id.clone(),
        eap_identity: credentials.username.clone(),
    })
}

pub fn build_plan_from_manifest(
    provider: &ProviderManifest,
    credentials: &ServiceCredentials,
    location_id: &str,
) -> Result<ConnectionPlan, CoreError> {
    let location = provider
        .location(location_id)
        .ok_or_else(|| CoreError::UnknownLocation(location_id.to_owned()))?;
    build_plan(&provider.id, credentials, location)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_valid_plan() {
        let creds = ServiceCredentials {
            username: "service-user".into(),
            password: "secret".into(),
        };
        let loc = Location {
            id: "tr-istanbul".into(),
            country: "Türkiye".into(),
            city: "Istanbul".into(),
            endpoint: Endpoint {
                hostname: "example.invalid".into(),
                fallback_ips: vec![],
                ike_port: 4500,
            },
            certificate_id: "provider-ca".into(),
        };

        let plan = build_plan("provider-a", &creds, &loc).unwrap();
        assert_eq!(plan.provider_id, "provider-a");
        assert_eq!(plan.location_id, "tr-istanbul");
        assert_eq!(plan.remote_port, 4500);
    }
}
