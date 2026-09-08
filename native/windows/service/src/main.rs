#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

#[cfg(windows)]
use serde::{Deserialize, Serialize};
#[cfg(windows)]
use std::{
    ffi::OsString,
    io::{BufRead, BufReader, Write},
    net::{IpAddr, TcpListener, TcpStream},
    path::PathBuf,
    process::Command,
    sync::mpsc,
    thread,
    time::Duration,
};
#[cfg(windows)]
use windows_service::{
    define_windows_service,
    service::{
        ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus,
        ServiceType,
    },
    service_control_handler::{self, ServiceControlHandlerResult},
    service_dispatcher,
};

#[cfg(windows)]
const SERVICE_NAME: &str = "MilMitVpnService";
#[cfg(windows)]
const SERVICE_TYPE: ServiceType = ServiceType::OWN_PROCESS;
#[cfg(windows)]
const IPC_ADDR: &str = "127.0.0.1:47631";

#[cfg(windows)]
define_windows_service!(ffi_service_main, service_main);

#[cfg(windows)]
#[derive(Debug, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
enum IpcRequest {
    Ping,
    KillSwitch {
        enabled: bool,
        interface_index: Option<u32>,
        endpoint_ip: Option<String>,
    },
}

#[cfg(windows)]
#[derive(Debug, Serialize)]
struct IpcResponse {
    ok: bool,
    error: Option<String>,
}

#[cfg(windows)]
fn main() -> Result<(), windows_service::Error> {
    service_dispatcher::start(SERVICE_NAME, ffi_service_main)
}

#[cfg(not(windows))]
fn main() {
    eprintln!("milmit-vpn-windows-service must be built and run on Windows");
}

#[cfg(windows)]
fn service_main(_arguments: Vec<OsString>) {
    if let Err(error) = run_service() {
        eprintln!("MilMitVpnService failed: {error}");
    }
}

#[cfg(windows)]
fn service_dir() -> Result<PathBuf, String> {
    std::env::current_exe()
        .map_err(|e| format!("current_exe failed: {e}"))?
        .parent()
        .map(PathBuf::from)
        .ok_or_else(|| "service executable has no parent directory".to_string())
}

#[cfg(windows)]
fn wfp_helper() -> Result<PathBuf, String> {
    let path = service_dir()?.join("wfp-helper.exe");
    if path.is_file() {
        Ok(path)
    } else {
        Err(format!("WFP helper is missing: {}", path.display()))
    }
}

#[cfg(windows)]
fn run_wfp(enable: bool, interface_index: Option<u32>, endpoint_ip: Option<&str>) -> Result<(), String> {
    let helper = wfp_helper()?;
    let mut command = Command::new(helper);
    if enable {
        let ifindex = interface_index.filter(|v| *v > 0).ok_or_else(|| "invalid interface index".to_string())?;
        let endpoint = endpoint_ip.ok_or_else(|| "missing VPN endpoint IP".to_string())?;
        let parsed: IpAddr = endpoint.parse().map_err(|_| "invalid VPN endpoint IP".to_string())?;
        command.arg("enable").arg(ifindex.to_string()).arg(parsed.to_string());
    } else {
        command.arg("disable");
    }

    let output = command.output().map_err(|e| format!("failed to launch WFP helper: {e}"))?;
    if output.status.success() {
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        Err(if stderr.is_empty() { stdout } else { stderr })
    }
}

#[cfg(windows)]
fn handle_request(request: IpcRequest) -> IpcResponse {
    let result = match request {
        IpcRequest::Ping => Ok(()),
        IpcRequest::KillSwitch {
            enabled,
            interface_index,
            endpoint_ip,
        } => run_wfp(enabled, interface_index, endpoint_ip.as_deref()),
    };
    match result {
        Ok(()) => IpcResponse { ok: true, error: None },
        Err(error) => IpcResponse { ok: false, error: Some(error) },
    }
}

#[cfg(windows)]
fn handle_client(mut stream: TcpStream) {
    let peer = match stream.peer_addr() {
        Ok(peer) if peer.ip().is_loopback() => peer,
        _ => return,
    };
    if !peer.ip().is_loopback() {
        return;
    }
    let _ = stream.set_read_timeout(Some(Duration::from_secs(3)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(3)));

    let cloned = match stream.try_clone() {
        Ok(v) => v,
        Err(_) => return,
    };
    let mut reader = BufReader::new(cloned);
    let mut line = String::new();
    let response = match reader.read_line(&mut line) {
        Ok(n) if n > 0 && line.len() <= 4096 => match serde_json::from_str::<IpcRequest>(line.trim()) {
            Ok(request) => handle_request(request),
            Err(error) => IpcResponse { ok: false, error: Some(format!("invalid request: {error}")) },
        },
        Ok(_) => IpcResponse { ok: false, error: Some("empty request".into()) },
        Err(error) => IpcResponse { ok: false, error: Some(format!("read failed: {error}")) },
    };

    if let Ok(mut json) = serde_json::to_vec(&response) {
        json.push(b'\n');
        let _ = stream.write_all(&json);
        let _ = stream.flush();
    }
}

#[cfg(windows)]
fn ipc_loop(shutdown_rx: mpsc::Receiver<()>) {
    let listener = match TcpListener::bind(IPC_ADDR) {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("MilMitVpnService IPC bind failed on {IPC_ADDR}: {error}");
            return;
        }
    };
    if listener.set_nonblocking(true).is_err() {
        return;
    }

    loop {
        if shutdown_rx.try_recv().is_ok() {
            break;
        }
        match listener.accept() {
            Ok((stream, _)) => {
                thread::spawn(move || handle_client(stream));
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(50));
            }
            Err(_) => thread::sleep(Duration::from_millis(100)),
        }
    }
}

#[cfg(windows)]
fn run_service() -> Result<(), windows_service::Error> {
    let (shutdown_tx, shutdown_rx) = mpsc::channel();
    let event_handler = move |control_event| -> ServiceControlHandlerResult {
        match control_event {
            ServiceControl::Stop | ServiceControl::Shutdown => {
                let _ = shutdown_tx.send(());
                ServiceControlHandlerResult::NoError
            }
            ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
            _ => ServiceControlHandlerResult::NotImplemented,
        }
    };

    let status_handle = service_control_handler::register(SERVICE_NAME, event_handler)?;
    status_handle.set_service_status(ServiceStatus {
        service_type: SERVICE_TYPE,
        current_state: ServiceState::Running,
        controls_accepted: ServiceControlAccept::STOP | ServiceControlAccept::SHUTDOWN,
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 0,
        wait_hint: Duration::default(),
        process_id: None,
    })?;

    ipc_loop(shutdown_rx);

    status_handle.set_service_status(ServiceStatus {
        service_type: SERVICE_TYPE,
        current_state: ServiceState::Stopped,
        controls_accepted: ServiceControlAccept::empty(),
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 0,
        wait_hint: Duration::default(),
        process_id: None,
    })?;
    Ok(())
}
