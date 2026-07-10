use rusqlite::{Result, Row};
use serde::Serialize;

#[derive(Serialize)]
pub struct ConductorSession {
    id: String,
    workspace_id: String,
    title: String,
    agent_type: String,
    is_hidden: bool,

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
        Self::load_with_workspace_id(None)
    }

    pub fn load_for_workspace(workspace_id: &str) -> Result<Vec<Self>, String> {
        Self::load_with_workspace_id(Some(workspace_id))
    }

    fn load_with_workspace_id(workspace_id: Option<&str>) -> Result<Vec<Self>, String> {
        let connection = crate::open_conductor_db_readonly()?;
        let (filter, limit) = match workspace_id {
            Some(_) => ("WHERE workspace_id = ?1", ""),
            None => ("", "LIMIT 200"),
        };

        let mut statement = connection
            .prepare(&format!(
                r#"
                SELECT
                    id,
                    workspace_id,
                    title,
                    agent_type,
                    is_hidden,
                    created_at,
                    updated_at,
                    last_user_message_at,
                    status,
                    model,
                    unread_count,
                    freshly_compacted,
                    context_token_count
                FROM sessions
                {filter}
                ORDER BY updated_at desc
                {limit}
                "#
            ))
            .map_err(|error| format!("Could not prepare sessions query: {error}"))?;

        let mut rows = match workspace_id {
            Some(workspace_id) => statement.query([workspace_id]),
            None => statement.query([]),
        }
        .map_err(|error| format!("Could not query sessions: {error}"))?;

        let mut sessions = Vec::new();

        while let Some(row) = rows
            .next()
            .map_err(|error| format!("Could not read session row: {error}"))?
        {
            sessions.push(
                Self::create_from_row(row)
                    .map_err(|error| format!("Could not read session row: {error}"))?,
            );
        }

        Ok(sessions)
    }

    pub fn create_from_row(row: &Row<'_>) -> Result<Self> {
        Ok(Self {
            id: row.get("id")?,
            workspace_id: row.get("workspace_id")?,
            title: row.get("title")?,
            agent_type: row.get("agent_type")?,
            is_hidden: row.get("is_hidden")?,
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
