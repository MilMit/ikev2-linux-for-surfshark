use once_cell::sync::Lazy;
use serde::Serialize;
use std::ffi::{c_char, CStr, CString};
use std::sync::Mutex;

#[derive(Debug, Clone, Serialize)]
struct BridgeState {
    status: &'static str,
    provider: &'static str,
    protocol: &'static str,
    location_id: Option<String>,
}

static STATE: Lazy<Mutex<BridgeState>> = Lazy::new(|| {
    Mutex::new(BridgeState {
        status: "disconnected",
        provider: "surfshark",
        protocol: "auto",
        location_id: None,
    })
});

#[derive(Debug, Serialize)]
struct ServerDto<'a> {
    id: &'a str,
    country: &'a str,
    city: &'a str,
    hostname: &'a str,
    latency_ms: u32,
}

fn into_c_string(value: String) -> *mut c_char {
    CString::new(value).unwrap_or_else(|_| CString::new("{\"ok\":false,\"error\":\"invalid_string\"}").unwrap()).into_raw()
}

fn json<T: Serialize>(value: &T) -> *mut c_char {
    into_c_string(serde_json::to_string(value).unwrap_or_else(|_| "{\"ok\":false,\"error\":\"serialization_failed\"}".into()))
}

#[no_mangle]
pub extern "C" fn milmit_vpn_version() -> *mut c_char {
    into_c_string("0.1.0".into())
}

#[no_mangle]
pub extern "C" fn milmit_vpn_get_state() -> *mut c_char {
    let state = STATE.lock().expect("state mutex poisoned").clone();
    json(&state)
}

#[no_mangle]
pub extern "C" fn milmit_vpn_list_servers() -> *mut c_char {
    let servers = [
        ServerDto { id: "de-fra", country: "Germany", city: "Frankfurt", hostname: "de-fra.prod.surfshark.com", latency_ms: 42 },
        ServerDto { id: "nl-ams", country: "Netherlands", city: "Amsterdam", hostname: "nl-ams.prod.surfshark.com", latency_ms: 48 },
        ServerDto { id: "gb-lon", country: "United Kingdom", city: "London", hostname: "uk-lon.prod.surfshark.com", latency_ms: 61 },
    ];
    json(&servers)
}

#[no_mangle]
pub unsafe extern "C" fn milmit_vpn_connect(location_id: *const c_char) -> *mut c_char {
    if location_id.is_null() {
        return into_c_string("{\"ok\":false,\"error\":\"location_required\"}".into());
    }
    let location = CStr::from_ptr(location_id).to_string_lossy().to_string();
    let mut state = STATE.lock().expect("state mutex poisoned");
    state.status = "connected";
    state.location_id = Some(location);
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
pub unsafe extern "C" fn milmit_vpn_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}
