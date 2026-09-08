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
    kill_switch: bool,
    dns_protection: bool,
    ipv6_protection: bool,
}

static STATE: Lazy<Mutex<BridgeState>> = Lazy::new(|| {
    Mutex::new(BridgeState {
        status: "disconnected",
        provider: "surfshark",
        protocol: "auto",
        location_id: None,
        kill_switch: true,
        dns_protection: true,
        ipv6_protection: true,
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
    CString::new(value)
        .unwrap_or_else(|_| CString::new("{\"ok\":false,\"error\":\"invalid_string\"}").unwrap())
        .into_raw()
}

fn json<T: Serialize>(value: &T) -> *mut c_char {
    into_c_string(
        serde_json::to_string(value)
            .unwrap_or_else(|_| "{\"ok\":false,\"error\":\"serialization_failed\"}".into()),
    )
}

fn ok() -> *mut c_char {
    into_c_string("{\"ok\":true}".into())
}

#[no_mangle]
pub extern "C" fn milmit_vpn_version() -> *mut c_char {
    into_c_string("0.2.0".into())
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
    ok()
}

#[no_mangle]
pub extern "C" fn milmit_vpn_disconnect() -> *mut c_char {
    let mut state = STATE.lock().expect("state mutex poisoned");
    state.status = "disconnected";
    state.location_id = None;
    ok()
}

#[no_mangle]
pub extern "C" fn milmit_vpn_set_kill_switch(enabled: bool) -> *mut c_char {
    STATE.lock().expect("state mutex poisoned").kill_switch = enabled;
    ok()
}

#[no_mangle]
pub extern "C" fn milmit_vpn_set_dns_protection(enabled: bool) -> *mut c_char {
    STATE.lock().expect("state mutex poisoned").dns_protection = enabled;
    ok()
}

#[no_mangle]
pub extern "C" fn milmit_vpn_set_ipv6_protection(enabled: bool) -> *mut c_char {
    STATE.lock().expect("state mutex poisoned").ipv6_protection = enabled;
    ok()
}

#[no_mangle]
pub extern "C" fn milmit_vpn_run_diagnostics() -> *mut c_char {
    let state = STATE.lock().expect("state mutex poisoned").clone();
    json(&serde_json::json!({
        "core": "rust-ffi",
        "version": "0.2.0",
        "provider": state.provider,
        "protocol": state.protocol,
        "status": state.status,
        "kill_switch": state.kill_switch,
        "dns_protection": state.dns_protection,
        "ipv6_protection": state.ipv6_protection,
        "network_adapter": "pending-platform-adapter"
    }))
}

#[no_mangle]
pub unsafe extern "C" fn milmit_vpn_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}
