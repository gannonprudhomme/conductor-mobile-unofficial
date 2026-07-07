use rusqlite::{Connection, OpenFlags, Result};
use std::path::PathBuf;
use crate::models::ConductorSession;

mod models;

fn conductor_db_path() -> Result<PathBuf, String> {
    let home = std::env::var("HOME")
        .map_err(|error| format!("Could not find HOME directory: {error}"))?;

    Ok(PathBuf::from(home)
        .join("Library")
        .join("Application Support")
        .join("com.conductor.app")
        .join("conductor.db")
    )
}

fn open_conductor_db_readonly() -> Result<Connection, String> {
    let db_path = conductor_db_path()?;
    
    let connection = Connection::open_with_flags(
        db_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY
    )
    .map_err(|error| format!("Could not open Conductor database: {error}"))?;

    connection.pragma_update(None, "query_only", true)
        .map_err(|error| format!("Could not enable query_only mode: {error}"))?;

    Ok(connection)
}

#[tauri::command]
fn list_sessions() -> Result<Vec<ConductorSession>, String> {
    let connection = open_conductor_db_readonly()?;

    let mut statement = connection
        .prepare(
            r#"
            SElECT
                id,
                workspace_id,
                title,
                agent_type,
                created_at,
                updated_at,
                last_user_message_at,
                status,
                model,
                unread_count,
                freshly_compacted,
                context_token_count
            FROM sessions
            ORDER BY updated_at desc
            limit 200
            "#,
        )
        .map_err(|error| format!("Could not prepare sessions query: {error}"))?;

let rows = statement
    .query_map([], ConductorSession::create_from_row)
    .map_err(|error| format!("Could not query sessions: {error}"))?;

    let mut sessions = Vec::new();

    for row in rows {
        sessions.push(row.map_err(|error| format!("Could not read session row: {error}"))?); 
    }

    Ok(sessions)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![list_sessions])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
