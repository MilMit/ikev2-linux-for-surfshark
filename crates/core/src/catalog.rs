use crate::{Location, ProviderManifest};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use thiserror::Error;

pub const CATALOG_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CatalogEnvelope {
    pub schema_version: u32,
    pub revision: u64,
    pub generated_at: String,
    pub provider: ProviderManifest,
    pub payload_sha256: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum CatalogSource {
    Bundled,
    Cache,
    Remote,
}

#[derive(Debug, Clone, Serialize)]
pub struct CatalogSnapshot {
    pub source: CatalogSource,
    pub revision: u64,
    pub provider_id: String,
    pub location_count: usize,
}

#[derive(Debug, Error)]
pub enum CatalogError {
    #[error("catalog JSON is invalid: {0}")]
    InvalidJson(#[from] serde_json::Error),
    #[error("unsupported catalog schema version: {0}")]
    UnsupportedSchema(u32),
    #[error("provider id is empty")]
    EmptyProvider,
    #[error("catalog provider mismatch: expected {expected}, got {actual}")]
    ProviderMismatch { expected: String, actual: String },
    #[error("catalog contains no locations")]
    EmptyLocations,
    #[error("catalog contains invalid location: {0}")]
    InvalidLocation(String),
    #[error("catalog checksum mismatch")]
    ChecksumMismatch,
    #[error("catalog revision is not newer")]
    StaleRevision,
    #[error("catalog I/O error: {0}")]
    Io(#[from] std::io::Error),
}

fn normalized_payload(provider: &ProviderManifest, revision: u64, generated_at: &str) -> Result<Vec<u8>, serde_json::Error> {
    #[derive(Serialize)]
    struct Payload<'a> {
        revision: u64,
        generated_at: &'a str,
        provider: &'a ProviderManifest,
    }
    serde_json::to_vec(&Payload { revision, generated_at, provider })
}

pub fn compute_payload_sha256(provider: &ProviderManifest, revision: u64, generated_at: &str) -> Result<String, serde_json::Error> {
    let bytes = normalized_payload(provider, revision, generated_at)?;
    Ok(hex::encode(Sha256::digest(bytes)))
}

fn validate_location(location: &Location) -> Result<(), CatalogError> {
    if location.id.trim().is_empty()
        || location.country.trim().is_empty()
        || location.city.trim().is_empty()
        || location.endpoint.hostname.trim().is_empty()
    {
        return Err(CatalogError::InvalidLocation(location.id.clone()));
    }
    if !matches!(location.endpoint.ike_port, 500 | 4500) {
        return Err(CatalogError::InvalidLocation(location.id.clone()));
    }
    Ok(())
}

pub fn validate_catalog(catalog: &CatalogEnvelope, expected_provider: Option<&str>) -> Result<(), CatalogError> {
    if catalog.schema_version != CATALOG_SCHEMA_VERSION {
        return Err(CatalogError::UnsupportedSchema(catalog.schema_version));
    }
    if catalog.provider.id.trim().is_empty() {
        return Err(CatalogError::EmptyProvider);
    }
    if let Some(expected) = expected_provider {
        if catalog.provider.id != expected {
            return Err(CatalogError::ProviderMismatch {
                expected: expected.to_owned(),
                actual: catalog.provider.id.clone(),
            });
        }
    }
    if catalog.provider.locations.is_empty() {
        return Err(CatalogError::EmptyLocations);
    }
    for location in &catalog.provider.locations {
        validate_location(location)?;
    }
    let expected_hash = compute_payload_sha256(&catalog.provider, catalog.revision, &catalog.generated_at)?;
    if !catalog.payload_sha256.eq_ignore_ascii_case(&expected_hash) {
        return Err(CatalogError::ChecksumMismatch);
    }
    Ok(())
}

pub fn parse_and_validate_catalog(json: &str, expected_provider: Option<&str>) -> Result<CatalogEnvelope, CatalogError> {
    let catalog: CatalogEnvelope = serde_json::from_str(json)?;
    validate_catalog(&catalog, expected_provider)?;
    Ok(catalog)
}

#[derive(Debug, Clone)]
pub struct CatalogStore {
    root: PathBuf,
}

impl CatalogStore {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    fn cache_path(&self, provider_id: &str) -> PathBuf {
        self.root.join(format!("{provider_id}.catalog.json"))
    }

    pub fn load_cache(&self, provider_id: &str) -> Result<Option<CatalogEnvelope>, CatalogError> {
        let path = self.cache_path(provider_id);
        if !path.exists() {
            return Ok(None);
        }
        let json = fs::read_to_string(path)?;
        match parse_and_validate_catalog(&json, Some(provider_id)) {
            Ok(catalog) => Ok(Some(catalog)),
            Err(_) => Ok(None),
        }
    }

    pub fn apply_remote(&self, json: &str, current_revision: u64, expected_provider: &str) -> Result<CatalogEnvelope, CatalogError> {
        let catalog = parse_and_validate_catalog(json, Some(expected_provider))?;
        if catalog.revision <= current_revision {
            return Err(CatalogError::StaleRevision);
        }
        fs::create_dir_all(&self.root)?;
        let target = self.cache_path(expected_provider);
        let temp = target.with_extension("json.tmp");
        {
            let mut file = fs::File::create(&temp)?;
            file.write_all(json.as_bytes())?;
            file.sync_all()?;
        }
        fs::rename(temp, target)?;
        Ok(catalog)
    }

    pub fn best_available(&self, bundled_json: &str, provider_id: &str) -> Result<(CatalogEnvelope, CatalogSource), CatalogError> {
        let bundled = parse_and_validate_catalog(bundled_json, Some(provider_id))?;
        if let Some(cached) = self.load_cache(provider_id)? {
            if cached.revision >= bundled.revision {
                return Ok((cached, CatalogSource::Cache));
            }
        }
        Ok((bundled, CatalogSource::Bundled))
    }
}

pub fn snapshot(catalog: &CatalogEnvelope, source: CatalogSource) -> CatalogSnapshot {
    CatalogSnapshot {
        source,
        revision: catalog.revision,
        provider_id: catalog.provider.id.clone(),
        location_count: catalog.provider.locations.len(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Endpoint, Location, ProviderManifest};

    fn sample() -> CatalogEnvelope {
        let provider = ProviderManifest {
            id: "provider-a".into(),
            display_name: "Provider A".into(),
            locations: vec![Location {
                id: "de-fra".into(),
                country: "Germany".into(),
                city: "Frankfurt".into(),
                endpoint: Endpoint { hostname: "de.example.invalid".into(), fallback_ips: vec![], ike_port: 4500 },
                certificate_id: "ca".into(),
            }],
        };
        let revision = 1;
        let generated_at = "2026-09-08T00:00:00Z".to_string();
        let payload_sha256 = compute_payload_sha256(&provider, revision, &generated_at).unwrap();
        CatalogEnvelope { schema_version: 1, revision, generated_at, provider, payload_sha256 }
    }

    #[test]
    fn validates_checksum_and_provider() {
        let catalog = sample();
        validate_catalog(&catalog, Some("provider-a")).unwrap();
    }

    #[test]
    fn rejects_tampered_catalog() {
        let mut catalog = sample();
        catalog.provider.locations[0].city = "Berlin".into();
        assert!(matches!(validate_catalog(&catalog, None), Err(CatalogError::ChecksumMismatch)));
    }
}
