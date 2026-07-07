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
    model: String, // "gpt-5.5", "sonnet", "opus-1m", "opus-4-8-1m", "opus", "gpt-5.3-codex"

    unread_count: i64,
    freshly_compacted: i64,
    context_token_count: i64,
}

impl ConductorSession {
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
            context_token_count: row.get("context_token_count")?
        })
    }
}
