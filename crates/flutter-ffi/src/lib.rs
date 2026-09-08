use once_cell::sync::Lazy;
use serde::Serialize;
use std::collections::HashMap;
use std::ffi::{c_char, CStr, CString};
use std::net::IpAddr;
use std::path::PathBuf;
use std::sync::Mutex;
use surfshark_ikev2_core::catalog::{parse_and_validate_catalog, snapshot, CatalogEnvelope, CatalogSource, CatalogStore, TrustedCatalogKey};
use surfshark_ikev2_core::health::HealthBook;
use surfshark_ikev2_core::ProviderManifest;

const SURFSHARK_CATALOG: &str = include_str!("../../../providers/surfshark/provider.json");
const SIGNING_KEY_ID: &str = match option_env!("VPN_CATALOG_ED25519_KEY_ID") { Some(v) => v, None => "release-1" };
const SIGNING_PUBLIC_KEY_HEX: Option<&str> = option_env!("VPN_CATALOG_ED25519_PUBLIC_KEY_HEX");

#[derive(Debug, Clone)]
struct ActiveCatalog { catalog: CatalogEnvelope, source: CatalogSource }

static CATALOGS: Lazy<Mutex<HashMap<String, ActiveCatalog>>> = Lazy::new(|| {
    let bundled = parse_and_validate_catalog(SURFSHARK_CATALOG, Some("surfshark")).expect("bundled Surfshark catalog is invalid");
    let mut map = HashMap::new();
    map.insert(bundled.provider.id.clone(), ActiveCatalog { catalog: bundled, source: CatalogSource::Bundled });
    Mutex::new(map)
});
static CACHE_ROOT: Lazy<Mutex<Option<PathBuf>>> = Lazy::new(|| Mutex::new(None));
static HEALTH: Lazy<Mutex<HealthBook>> = Lazy::new(|| Mutex::new(HealthBook::default()));
static ENDPOINT_CURSOR: Lazy<Mutex<HashMap<String, usize>>> = Lazy::new(|| Mutex::new(HashMap::new()));

#[derive(Debug, Clone, Serialize)]
struct BridgeState {
    status: &'static str,
    provider: String,
    protocol: String,
    location_id: Option<String>,
    kill_switch: bool,
    dns_protection: bool,
    ipv6_protection: bool,
}

static STATE: Lazy<Mutex<BridgeState>> = Lazy::new(|| Mutex::new(BridgeState {
    status: "disconnected",
    provider: "surfshark".into(),
    protocol: "auto".into(),
    location_id: None,
    kill_switch: true,
    dns_protection: true,
    ipv6_protection: true,
}));

#[derive(Debug, Serialize)]
struct ServerDto {
    id: String,
    provider_id: String,
    country: String,
    city: String,
    hostname: String,
    latency_ms: Option<u32>,
    health_score: u64,
    consecutive_failures: u32,
}

fn into_c_string(value: String) -> *mut c_char {
    CString::new(value).unwrap_or_else(|_| CString::new("{\"ok\":false,\"error\":\"invalid_string\"}").unwrap()).into_raw()
}
fn json<T: Serialize>(value: &T) -> *mut c_char {
    into_c_string(serde_json::to_string(value).unwrap_or_else(|_| "{\"ok\":false,\"error\":\"serialization_failed\"}".into()))
}
fn cstr(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() { return None; }
    Some(unsafe { CStr::from_ptr(ptr) }.to_string_lossy().to_string())
}
fn active_provider(id: &str) -> Option<ProviderManifest> {
    CATALOGS.lock().ok()?.get(id).map(|item| item.catalog.provider.clone())
}
fn active_revision(id: &str) -> u64 {
    CATALOGS.lock().ok().and_then(|m| m.get(id).map(|item| item.catalog.revision)).unwrap_or(0)
}
fn trusted_keys() -> Result<Vec<TrustedCatalogKey>, String> {
    let Some(hex_key) = SIGNING_PUBLIC_KEY_HEX else { return Ok(vec![]); };
    let raw = hex::decode(hex_key).map_err(|_| "invalid_catalog_public_key_hex".to_string())?;
    let public_key: [u8; 32] = raw.try_into().map_err(|_| "catalog_public_key_must_be_32_bytes".to_string())?;
    Ok(vec![TrustedCatalogKey { key_id: SIGNING_KEY_ID.to_string(), public_key }])
}
fn reload_best(provider_id: &str) -> Result<(), String> {
    let cache_root = CACHE_ROOT.lock().map_err(|_| "cache mutex poisoned".to_string())?.clone();
    let bundled_json = match provider_id { "surfshark" => SURFSHARK_CATALOG, _ => return Err("unknown_provider".into()) };
    let active = if let Some(root) = cache_root {
        let store = CatalogStore::new(root);
        let (catalog, source) = store.best_available(bundled_json, provider_id).map_err(|e| e.to_string())?;
        ActiveCatalog { catalog, source }
    } else {
        let catalog = parse_and_validate_catalog(bundled_json, Some(provider_id)).map_err(|e| e.to_string())?;
        ActiveCatalog { catalog, source: CatalogSource::Bundled }
    };
    CATALOGS.lock().map_err(|_| "catalog mutex poisoned".to_string())?.insert(provider_id.to_string(), active);
    Ok(())
}
fn endpoint_candidates(provider_id: &str, location_id: &str) -> Option<Vec<String>> {
    let provider = active_provider(provider_id)?;
    let location = provider.location(location_id)?;
    let mut values = vec![location.endpoint.hostname.clone()];
    values.extend(location.endpoint.fallback_ips.iter().map(IpAddr::to_string));
    Some(values)
}

#[no_mangle]
pub extern "C" fn milmit_vpn_version() -> *mut c_char { into_c_string("0.4.0".into()) }

#[no_mangle]
pub unsafe extern "C" fn milmit_vpn_init(cache_root: *const c_char) -> *mut c_char {
    if let Some(path) = cstr(cache_root) { *CACHE_ROOT.lock().expect("cache mutex poisoned") = Some(PathBuf::from(path)); }
    match reload_best("surfshark") { Ok(()) => into_c_string("{\"ok\":true}".into()), Err(error) => json(&serde_json::json!({"ok": false, "error": error})) }
}

#[no_mangle]
pub extern "C" fn milmit_vpn_get_state() -> *mut c_char { json(&STATE.lock().expect("state mutex poisoned").clone()) }

#[no_mangle]
pub unsafe extern "C" fn milmit_vpn_list_servers(provider_id: *const c_char) -> *mut c_char {
    let provider_id = cstr(provider_id).unwrap_or_else(|| "surfshark".into());
    let Some(provider) = active_provider(&provider_id) else { return into_c_string("[]".into()); };
    let health = HEALTH.lock().expect("health mutex poisoned");
    let ranked = health.ranked_ids(provider.locations.iter().map(|location| location.id.as_str()));
    let by_id: HashMap<_, _> = provider.locations.iter().map(|l| (l.id.as_str(), l)).collect();
    let servers: Vec<_> = ranked.into_iter().filter_map(|id| by_id.get(id.as_str())).map(|location| {
        let h = health.get(&location.id);
        ServerDto {
            id: location.id.clone(), provider_id: provider.id.clone(), country: location.country.clone(), city: location.city.clone(),
            hostname: location.endpoint.hostname.clone(), latency_ms: h.latency_ms, health_score: h.score(), consecutive_failures: h.consecutive_failures,
        }
    }).collect();
    json(&servers)
}

#[no_mangle]
pub unsafe extern "C" fn milmit_vpn_report_server_health(server_id: *const c_char, latency_ms: i64, outcome: i32) -> *mut c_char {
    let Some(server_id) = cstr(server_id) else { return into_c_string("{\"ok\":false,\"error\":\"server_required\"}".into()); };
    let mut health = HEALTH.lock().expect("health mutex poisoned");
    if latency_ms >= 0 { health.report_latency(server_id.clone(), latency_ms as u32); }
    match outcome { 1 => health.report_success(server_id), -1 => health.report_failure(server_id), _ => {} }
    into_c_string("{\"ok\":true}".into())
}

#[no_mangle]
pub unsafe extern "C" fn milmit_vpn_next_endpoint(provider_id: *const c_char, location_id: *const c_char) -> *mut c_char {
    let Some(provider_id) = cstr(provider_id) else { return into_c_string("{\"ok\":false,\"error\":\"provider_required\"}".into()); };
    let Some(location_id) = cstr(location_id) else { return into_c_string("{\"ok\":false,\"error\":\"location_required\"}".into()); };
    let Some(candidates) = endpoint_candidates(&provider_id, &location_id) else { return into_c_string("{\"ok\":false,\"error\":\"unknown_location\"}".into()); };
    if candidates.is_empty() { return into_c_string("{\"ok\":false,\"error\":\"no_endpoints\"}".into()); }
    let key = format!("{provider_id}:{location_id}");
    let mut cursors = ENDPOINT_CURSOR.lock().expect("endpoint mutex poisoned");
    let cursor = cursors.entry(key).or_insert(0);
    let index = *cursor % candidates.len();
    let selected = candidates[index].clone();
    *cursor = (index + 1) % candidates.len();
    json(&serde_json::json!({"ok": true, "endpoint": selected, "index": index, "count": candidates.len()}))
}

#[no_mangle]
pub unsafe extern "C" fn milmit_vpn_apply_catalog_update(provider_id: *const c_char, catalog_json: *const c_char) -> *mut c_char {
    let Some(provider_id) = cstr(provider_id) else { return into_c_string("{\"ok\":false,\"error\":\"provider_required\"}".into()); };
    let Some(catalog_json) = cstr(catalog_json) else { return into_c_string("{\"ok\":false,\"error\":\"catalog_required\"}".into()); };
    let Some(root) = CACHE_ROOT.lock().expect("cache mutex poisoned").clone() else { return into_c_string("{\"ok\":false,\"error\":\"cache_not_initialized\"}".into()); };
    let keys = match trusted_keys() { Ok(keys) if !keys.is_empty() => keys, Ok(_) => return into_c_string("{\"ok\":false,\"error\":\"catalog_signing_key_not_configured\"}".into()), Err(error) => return json(&serde_json::json!({"ok": false, "error": error})) };
    let store = CatalogStore::new(root);
    match store.apply_remote_signed(&catalog_json, active_revision(&provider_id), &provider_id, &keys) {
        Ok(catalog) => {
            let snap = snapshot(&catalog, CatalogSource::Remote);
            CATALOGS.lock().expect("catalog mutex poisoned").insert(provider_id, ActiveCatalog { catalog, source: CatalogSource::Remote });
            json(&serde_json::json!({"ok": true, "snapshot": snap}))
        }
        Err(error) => json(&serde_json::json!({"ok": false, "error": error.to_string()})),
    }
}

#[no_mangle]
pub unsafe extern "C" fn milmit_vpn_connect(provider_id: *const c_char, location_id: *const c_char, protocol: *const c_char) -> *mut c_char {
    let Some(provider_id) = cstr(provider_id) else { return into_c_string("{\"ok\":false,\"error\":\"provider_required\"}".into()); };
    let Some(location_id) = cstr(location_id) else { return into_c_string("{\"ok\":false,\"error\":\"location_required\"}".into()); };
    let protocol = cstr(protocol).unwrap_or_else(|| "auto".into());
    let Some(provider) = active_provider(&provider_id) else { return into_c_string("{\"ok\":false,\"error\":\"unknown_provider\"}".into()); };
    if provider.location(&location_id).is_none() { return into_c_string("{\"ok\":false,\"error\":\"unknown_location\"}".into()); }
    let mut state = STATE.lock().expect("state mutex poisoned");
    state.status = "connected"; state.provider = provider_id; state.protocol = protocol; state.location_id = Some(location_id);
    into_c_string("{\"ok\":true}".into())
}

#[no_mangle]
pub extern "C" fn milmit_vpn_disconnect() -> *mut c_char {
    let mut state = STATE.lock().expect("state mutex poisoned"); state.status = "disconnected"; state.location_id = None;
    into_c_string("{\"ok\":true}".into())
}
#[no_mangle]
pub extern "C" fn milmit_vpn_set_kill_switch(enabled: bool) -> *mut c_char { STATE.lock().expect("state mutex poisoned").kill_switch = enabled; into_c_string("{\"ok\":true}".into()) }
#[no_mangle]
pub extern "C" fn milmit_vpn_set_dns_protection(enabled: bool) -> *mut c_char { STATE.lock().expect("state mutex poisoned").dns_protection = enabled; into_c_string("{\"ok\":true}".into()) }
#[no_mangle]
pub extern "C" fn milmit_vpn_set_ipv6_protection(enabled: bool) -> *mut c_char { STATE.lock().expect("state mutex poisoned").ipv6_protection = enabled; into_c_string("{\"ok\":true}".into()) }

#[no_mangle]
pub extern "C" fn milmit_vpn_diagnostics() -> *mut c_char {
    let state = STATE.lock().expect("state mutex poisoned").clone();
    let catalogs = CATALOGS.lock().expect("catalog mutex poisoned");
    let catalog = catalogs.get(&state.provider);
    json(&serde_json::json!({
        "core": "rust-ffi", "version": "0.4.0", "providers": catalogs.len(), "provider": state.provider,
        "catalog_revision": catalog.map(|c| c.catalog.revision).unwrap_or(0),
        "catalog_source": catalog.map(|c| format!("{:?}", c.source)).unwrap_or_else(|| "Unknown".into()),
        "catalog_signed": catalog.and_then(|c| c.catalog.signature.as_ref()).is_some(),
        "signing_key_configured": SIGNING_PUBLIC_KEY_HEX.is_some(),
        "locations": catalog.map(|c| c.catalog.provider.locations.len()).unwrap_or(0),
        "cache_configured": CACHE_ROOT.lock().map(|p| p.is_some()).unwrap_or(false),
        "kill_switch": state.kill_switch, "dns_protection": state.dns_protection, "ipv6_protection": state.ipv6_protection,
        "network_adapter": "pending-platform-adapter"
    }))
}

#[no_mangle]
pub unsafe extern "C" fn milmit_vpn_string_free(ptr: *mut c_char) { if !ptr.is_null() { drop(CString::from_raw(ptr)); } }
