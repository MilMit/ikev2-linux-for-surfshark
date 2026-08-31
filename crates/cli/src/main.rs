use std::{env, fs, process};
use surfshark_ikev2_core::{build_plan, Location, ServiceCredentials};

fn main() {
    let path = env::args()
        .nth(1)
        .unwrap_or_else(|| "providers/surfshark/locations.example.json".to_string());

    let raw = fs::read_to_string(&path).unwrap_or_else(|e| {
        eprintln!("failed to read {path}: {e}");
        process::exit(1);
    });

    let locations: Vec<Location> = serde_json::from_str(&raw).unwrap_or_else(|e| {
        eprintln!("invalid provider database: {e}");
        process::exit(1);
    });

    let Some(location) = locations.first() else {
        eprintln!("provider database is empty");
        process::exit(1);
    };

    let username = env::var("SURFSHARK_SERVICE_USER").unwrap_or_else(|_| {
        eprint!("Surfshark service username: ");
        use std::io::Write;
        std::io::stderr().flush().ok();
        let mut s = String::new();
        std::io::stdin().read_line(&mut s).expect("stdin");
        s.trim().to_string()
    });

    let password = env::var("SURFSHARK_SERVICE_PASS")
        .unwrap_or_else(|_| rpassword::prompt_password("Surfshark service password: ").expect("password"));

    let creds = ServiceCredentials { username, password };

    match build_plan(&creds, location) {
        Ok(plan) => {
            println!("Connection plan ready:");
            println!("  location: {}", plan.location_id);
            println!("  hostname: {}", plan.remote_hostname);
            println!("  port: {}", plan.remote_port);
            println!("  fallback IPs: {}", plan.fallback_ips.len());
            println!("  certificate: {}", plan.certificate_id);
            println!();
            println!("No VPN connection is performed yet.");
        }
        Err(e) => {
            eprintln!("cannot build connection plan: {e}");
            process::exit(1);
        }
    }
}
