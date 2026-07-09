use rusqlite::{Result, Row};
use serde::Serialize;

#[derive(Serialize)]
pub struct ConductorSession {
    id: String,
    workspace_id: String,
    title: String,
    agent_type: String,

    created_at: String,
    updated_at: String,
    last_user_message_at: Option<String>,

    status: String, // "idle", "error", "working"
    model: String,  // "gpt-5.5", "sonnet", "opus-1m", "opus-4-8-1m", "opus", "gpt-5.3-codex"

    unread_count: i64,
    freshly_compacted: i64,
    context_token_count: i64,
}

impl ConductorSession {
    pub fn load() -> Result<Vec<Self>, String> {
        let connection = crate::open_conductor_db_readonly()?;

        let mut statement = connection
            .prepare(
                r#"
                SELECT
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
            .query_map([], Self::create_from_row)
            .map_err(|error| format!("Could not query sessions: {error}"))?;

        let mut sessions = Vec::new();

        for row in rows {
            sessions.push(row.map_err(|error| format!("Could not read session row: {error}"))?);
        }

        Ok(sessions)
    }

    pub fn create_from_row(row: &Row<'_>) -> Result<Self> {
        Ok(Self {
            id: row.get("id")?,
            workspace_id: row.get("workspace_id")?,
            title: row.get("title")?,
            agent_type: row.get("agent_type")?,
            created_at: row.get("created_at")?,
            updated_at: row.get("updated_at")?,
            last_user_message_at: row.get("last_user_message_at")?,
            status: row.get("status")?,
            model: row.get("model")?,
            unread_count: row.get("unread_count")?,
            freshly_compacted: row.get("freshly_compacted")?,
            context_token_count: row.get("context_token_count")?,
        })
    }
}
