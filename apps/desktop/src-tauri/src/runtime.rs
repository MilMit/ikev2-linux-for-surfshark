use std::{fs, process::Command, thread, time::Duration};
use tauri::{
    image::Image,
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    Manager,
};

const HELPER: &str = "/usr/libexec/milmit-surfshark-helper";
const STATE: &str = "/run/milmit-surfshark/restricted.state";

fn connected() -> bool {
    fs::metadata("/sys/class/net/milmitxfrm0").is_ok() && fs::metadata(STATE).is_ok()
}

fn status_icon(ok: bool) -> Image<'static> {
    // Original MilMit status glyph: a compact rounded dot with a light inner core.
    // Green = protected, red = disconnected. We generate RGBA at runtime so the
    // tray state is visible without copying any third-party icon asset.
    let size = 22u32;
    let mut rgba = vec![0u8; (size * size * 4) as usize];
    let (r, g, b) = if ok { (55u8, 196u8, 125u8) } else { (220u8, 74u8, 78u8) };
    let c = (size as f32 - 1.0) / 2.0;
    for y in 0..size {
        for x in 0..size {
            let dx = x as f32 - c;
            let dy = y as f32 - c;
            let d2 = dx * dx + dy * dy;
            let i = ((y * size + x) * 4) as usize;
            if d2 <= 92.0 {
                rgba[i] = r;
                rgba[i + 1] = g;
                rgba[i + 2] = b;
                rgba[i + 3] = 255;
            }
            if d2 <= 22.0 {
                rgba[i] = 245;
                rgba[i + 1] = 251;
                rgba[i + 2] = 255;
                rgba[i + 3] = 255;
            }
        }
    }
    Image::new_owned(rgba, size, size)
}

fn spawn_helper(action: &'static str) {
    thread::spawn(move || {
        let seconds = if action == "disconnect" { "18s" } else { "45s" };
        let _ = Command::new("timeout")
            .args(["--signal=TERM", seconds, "pkexec", HELPER, action])
            .output();
    });
}

pub fn setup(app: &tauri::App) -> tauri::Result<()> {
    let open = MenuItem::with_id(app, "tray-open", "Open MilMit Secure", true, None::<&str>)?;
    let status = MenuItem::with_id(app, "tray-status", "● Checking connection…", false, None::<&str>)?;
    let connect = MenuItem::with_id(app, "tray-connect", "Connect", true, None::<&str>)?;
    let disconnect = MenuItem::with_id(app, "tray-disconnect", "Disconnect", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "tray-quit", "Quit", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&open, &status, &connect, &disconnect, &quit])?;

    let initial = connected();
    let tray = TrayIconBuilder::with_id("milmit-status")
        .icon(status_icon(initial))
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "tray-open" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.unminimize();
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
            "tray-connect" => spawn_helper("quick-connect"),
            "tray-disconnect" => spawn_helper("disconnect"),
            "tray-quit" => app.exit(0),
            _ => {}
        })
        .build(app)?;

    let status_item = status.clone();
    thread::spawn(move || {
        let mut last: Option<bool> = None;
        loop {
            let now = connected();
            if last != Some(now) {
                let _ = tray.set_icon(Some(status_icon(now)));
                let _ = status_item.set_text(if now { "● Connected · Protected" } else { "● Disconnected" });
                last = Some(now);
            }
            thread::sleep(Duration::from_secs(2));
        }
    });
    Ok(())
}
