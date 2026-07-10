use crate::models::{ConductorRepository, ConductorSession, ConductorWorkspace};
use axum::{extract::Path, http::StatusCode, response::IntoResponse, routing::get, Json, Router};
use rusqlite::{Connection, OpenFlags, Result};
use std::{path::PathBuf, time::Duration};

mod bridge_installer;
mod models;

fn conductor_db_path() -> Result<PathBuf, String> {
    let home =
        std::env::var("HOME").map_err(|error| format!("Could not find HOME directory: {error}"))?;

    Ok(PathBuf::from(home)
        .join("Library")
        .join("Application Support")
        .join("com.conductor.app")
        .join("conductor.db"))
}

pub(crate) fn open_conductor_db_readonly() -> Result<Connection, String> {
    let db_path = conductor_db_path()?;

    let connection = Connection::open_with_flags(db_path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|error| format!("Could not open Conductor database: {error}"))?;

    connection
        .pragma_update(None, "query_only", true)
        .map_err(|error| format!("Could not enable query_only mode: {error}"))?;

    Ok(connection)
}

async fn get_sessions() -> impl IntoResponse {
    match ConductorSession::load() {
        Ok(sessions) => Ok(Json(sessions)),
        Err(error) => Err((StatusCode::INTERNAL_SERVER_ERROR, error)),
    }
}

async fn get_workspace_sessions(Path(workspace_id): Path<String>) -> impl IntoResponse {
    match ConductorSession::load_for_workspace(&workspace_id) {
        Ok(sessions) => Ok(Json(sessions)),
        Err(error) => Err((StatusCode::INTERNAL_SERVER_ERROR, error)),
    }
}

async fn get_workspaces() -> impl IntoResponse {
    match ConductorWorkspace::load() {
        Ok(workspaces) => Ok(Json(workspaces)),
        Err(error) => Err((StatusCode::INTERNAL_SERVER_ERROR, error)),
    }
}

async fn get_repositories() -> impl IntoResponse {
    match ConductorRepository::load() {
        Ok(repositories) => Ok(Json(repositories)),
        Err(error) => Err((StatusCode::INTERNAL_SERVER_ERROR, error)),
    }
}

fn start_mobile_api_server() {
    tauri::async_runtime::spawn(async {
        let app = Router::new()
            .route("/sessions", get(get_sessions))
            .route("/workspaces", get(get_workspaces))
            .route("/repositories", get(get_repositories))
            .route(
                "/workspaces/{workspace_id}/sessions",
                get(get_workspace_sessions),
            );

        let listener = match tokio::net::TcpListener::bind("127.0.0.1:3768").await {
            Ok(listener) => listener,
            Err(error) => {
                eprintln!("Could not bind mobile API server: {error}");
                return;
            }
        };

        if let Err(error) = axum::serve(listener, app).await {
            eprintln!("Mobile API server failed: {error}");
        }
    });
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let bridge_client = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
        .expect("Could not create bridge HTTP client");

    tauri::Builder::default()
        .setup(|_app| {
            start_mobile_api_server();
            Ok(())
        })
        .manage(bridge_client)
        .plugin(tauri_plugin_opener::init())
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
                use tauri::Manager;

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
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
