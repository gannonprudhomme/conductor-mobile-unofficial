use std::sync::Mutex;

use tauri::{Manager, RunEvent};
use tauri_plugin_shell::{
    process::{CommandChild, CommandEvent},
    ShellExt,
};

mod bridge_installer;

struct MobileServerSidecar {
    child: Mutex<Option<CommandChild>>,
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let bridge_client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .expect("Could not create bridge HTTP client");

    let app = tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_shell::init())
        .manage(bridge_client)
        .setup(|app| {
            let (mut events, child) = app.shell().sidecar("conductor-mobile-server")?.spawn()?;

            tauri::async_runtime::spawn(async move {
                while let Some(event) = events.recv().await {
                    match event {
                        CommandEvent::Stdout(bytes) => {
                            println!(
                                "conductor-mobile-server: {}",
                                String::from_utf8_lossy(&bytes)
                            );
                        }
                        CommandEvent::Stderr(bytes) => {
                            eprintln!(
                                "conductor-mobile-server: {}",
                                String::from_utf8_lossy(&bytes)
                            );
                        }
                        CommandEvent::Error(error) => {
                            eprintln!("conductor-mobile-server: {error}");
                        }
                        CommandEvent::Terminated(payload) => {
                            eprintln!(
                                "conductor-mobile-server exited: code={:?}, signal={:?}",
                                payload.code, payload.signal
                            );
                            break;
                        }
                        _ => {}
                    }
                }
            });

            app.manage(MobileServerSidecar {
                child: Mutex::new(Some(child)),
            });
            Ok(())
        })
        .menu(|handle| {
            let toggle_devtools =
                tauri::menu::MenuItemBuilder::with_id("toggle-devtools", "Toggle Dev Tools")
                    .accelerator("CmdOrCtrl+Shift+I")
                    .build(handle)?;

            let view_menu = tauri::menu::SubmenuBuilder::new(handle, "View")
                .item(&toggle_devtools)
                .build()?;

            let menu = tauri::menu::Menu::new(handle)?;
            menu.append(&view_menu)?;
            Ok(menu)
        })
        .on_menu_event(|app, event| {
            #[cfg(debug_assertions)]
            if event.id() == "toggle-devtools" {
                if let Some(window) = app.get_webview_window("main") {
                    if window.is_devtools_open() {
                        window.close_devtools();
                    } else {
                        window.open_devtools();
                    }
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            bridge_installer::install_bridge,
            bridge_installer::uninstall_bridge,
            bridge_installer::get_bridge_status,
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri application");

    app.run(|app, event| {
        if let RunEvent::Exit = event {
            let sidecar = app.state::<MobileServerSidecar>();
            let child = sidecar
                .child
                .lock()
                .expect("mobile server sidecar lock poisoned")
                .take();
            if let Some(child) = child {
                let _ = child.kill();
            }
        }
    });
}
