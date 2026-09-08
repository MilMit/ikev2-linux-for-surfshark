use once_cell::sync::Lazy;
use serde::Serialize;
use std::ffi::{c_char, CStr, CString};
use std::sync::Mutex;
use surfshark_ikev2_core::ProviderManifest;

const SURFSHARK_MANIFEST: &str = include_str!("../../../providers/surfshark/provider.json");

static PROVIDERS: Lazy<Vec<ProviderManifest>> = Lazy::new(|| {
    vec![serde_json::from_str(SURFSHARK_MANIFEST).expect("bundled Surfshark provider manifest is invalid")]
});

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

static STATE: Lazy<Mutex<BridgeState>> = Lazy::new(|| {
    Mutex::new(BridgeState {
        status: "disconnected",
        provider: "surfshark".into(),
        protocol: "auto".into(),
        location_id: None,
        kill_switch: true,
        dns_protection: true,
        ipv6_protection: true,
    })
});

#[derive(Debug, Serialize)]
struct ServerDto<'a> {
    id: &'a str,
    provider_id: &'a str,
    country: &'a str,
    city: &'a str,
    hostname: &'a str,
    latency_ms: Option<u32>,
}

fn into_c_string(value: String) -> *mut c_char {
    CString::new(value)
        .unwrap_or_else(|_| CString::new("{\"ok\":false,\"error\":\"invalid_string\"}").unwrap())
        .into_raw()
}

fn json<T: Serialize>(value: &T) -> *mut c_char {
    into_c_string(serde_json::to_string(value).unwrap_or_else(|_| {
        "{\"ok\":false,\"error\":\"serialization_failed\"}".into()
    }))
}

fn provider(id: &str) -> Option<&'static ProviderManifest> {
    PROVIDERS.iter().find(|provider| provider.id == id)
}

fn cstr(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() { return None; }
    Some(unsafe { CStr::from_ptr(ptr) }.to_string_lossy().to_string())
}

#[no_mangle]
pub extern "C" fn milmit_vpn_version() -> *mut c_char {
    into_c_string("0.2.0".into())
}

#[no_mangle]
pub extern "C" fn milmit_vpn_get_state() -> *mut c_char {
    json(&STATE.lock().expect("state mutex poisoned").clone())
}

#[no_mangle]
pub extern "C" fn milmit_vpn_list_providers() -> *mut c_char {
    #[derive(Serialize)]
    struct ProviderDto<'a> { id: &'a str, display_name: &'a str }
    let providers: Vec<_> = PROVIDERS.iter().map(|p| ProviderDto { id: &p.id, display_name: &p.display_name }).collect();
    json(&providers)
}

#[no_mangle]
pub unsafe extern "C" fn milmit_vpn_list_servers(provider_id: *const c_char) -> *mut c_char {
    let provider_id = cstr(provider_id).unwrap_or_else(|| "surfshark".into());
    let Some(provider) = provider(&provider_id) else {
        return into_c_string("[]".into());
    };
    let servers: Vec<_> = provider.locations.iter().map(|location| ServerDto {
        id: &location.id,
        provider_id: &provider.id,
        country: &location.country,
        city: &location.city,
        hostname: &location.endpoint.hostname,
        latency_ms: None,
    }).collect();
    json(&servers)
}

#[no_mangle]
pub unsafe extern "C" fn milmit_vpn_connect(provider_id: *const c_char, location_id: *const c_char, protocol: *const c_char) -> *mut c_char {
    let Some(provider_id) = cstr(provider_id) else { return into_c_string("{\"ok\":false,\"error\":\"provider_required\"}".into()); };
    let Some(location_id) = cstr(location_id) else { return into_c_string("{\"ok\":false,\"error\":\"location_required\"}".into()); };
    let protocol = cstr(protocol).unwrap_or_else(|| "auto".into());
    let Some(provider) = provider(&provider_id) else { return into_c_string("{\"ok\":false,\"error\":\"unknown_provider\"}".into()); };
    if provider.location(&location_id).is_none() { return into_c_string("{\"ok\":false,\"error\":\"unknown_location\"}".into()); }

    let mut state = STATE.lock().expect("state mutex poisoned");
    state.status = "connected";
    state.provider = provider_id;
    state.protocol = protocol;
    state.location_id = Some(location_id);
    into_c_string("{\"ok\":true}".into())
}

#[no_mangle]
pub extern "C" fn milmit_vpn_disconnect() -> *mut c_char {
    let mut state = STATE.lock().expect("state mutex poisoned");
    state.status = "disconnected";
    state.location_id = None;
    into_c_string("{\"ok\":true}".into())
}

#[no_mangle]
pub extern "C" fn milmit_vpn_set_kill_switch(enabled: bool) -> *mut c_char {
    STATE.lock().expect("state mutex poisoned").kill_switch = enabled;
    into_c_string("{\"ok\":true}".into())
}

#[no_mangle]
pub extern "C" fn milmit_vpn_set_dns_protection(enabled: bool) -> *mut c_char {
    STATE.lock().expect("state mutex poisoned").dns_protection = enabled;
    into_c_string("{\"ok\":true}".into())
}

#[no_mangle]
pub extern "C" fn milmit_vpn_set_ipv6_protection(enabled: bool) -> *mut c_char {
    STATE.lock().expect("state mutex poisoned").ipv6_protection = enabled;
    into_c_string("{\"ok\":true}".into())
}

#[no_mangle]
pub extern "C" fn milmit_vpn_diagnostics() -> *mut c_char {
    let state = STATE.lock().expect("state mutex poisoned").clone();
    json(&serde_json::json!({
        "core": "rust-ffi",
        "version": "0.2.0",
        "providers": PROVIDERS.len(),
        "provider": state.provider,
        "bundled_locations": provider(&state.provider).map(|p| p.locations.len()).unwrap_or(0),
        "kill_switch": state.kill_switch,
        "dns_protection": state.dns_protection,
        "ipv6_protection": state.ipv6_protection,
        "network_adapter": "pending-platform-adapter"
    }))
}

#[no_mangle]
pub unsafe extern "C" fn milmit_vpn_string_free(ptr: *mut c_char) {
    if !ptr.is_null() { drop(CString::from_raw(ptr)); }
}
