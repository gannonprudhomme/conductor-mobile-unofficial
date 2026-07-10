use rusqlite::{Result, Row};
use serde::Serialize;

#[derive(Serialize)]
pub struct ConductorMessage {
    id: String,
    session_id: Option<String>,
    role: Option<String>,
    content: Option<String>,
    created_at: String,
    sent_at: Option<String>,
    full_message: Option<String>,
    cancelled_at: Option<String>,
    model: Option<String>,
    sdk_message_id: Option<String>,
    last_assistant_message_id: Option<String>,
    turn_id: Option<String>,
    is_resumable_message: Option<i64>,
    queue_order: Option<i64>,
    sender_id: Option<String>,
}

impl ConductorMessage {
    pub fn load_for_session(workspace_id: &str, session_id: &str) -> Result<Vec<Self>, String> {
        let connection = crate::open_conductor_db_readonly()?;
        let mut statement = connection
            .prepare(
                r#"
                SELECT
                    m.id,
                    m.session_id,
                    m.role,
                    m.content,
                    m.created_at,
                    m.sent_at,
                    m.full_message,
                    m.cancelled_at,
                    m.model,
                    m.sdk_message_id,
                    m.last_assistant_message_id,
                    m.turn_id,
                    m.is_resumable_message,
                    m.queue_order,
                    m.sender_id
                FROM session_messages m
                JOIN sessions s ON s.id = m.session_id
                WHERE m.session_id = ?1 AND s.workspace_id = ?2
                ORDER BY m.created_at ASC
                "#,
            )
            .map_err(|error| format!("Could not prepare messages query: {error}"))?;

        let rows = statement
            .query_map([session_id, workspace_id], Self::create_from_row)
            .map_err(|error| format!("Could not query messages: {error}"))?;

        let mut messages = Vec::new();
        for row in rows {
            messages.push(row.map_err(|error| format!("Could not read message row: {error}"))?);
        }
        Ok(messages)
    }

    fn create_from_row(row: &Row<'_>) -> Result<Self> {
        Ok(Self {
            id: row.get("id")?,
            session_id: row.get("session_id")?,
            role: row.get("role")?,
            content: row.get("content")?,
            created_at: row.get("created_at")?,
            sent_at: row.get("sent_at")?,
            full_message: row.get("full_message")?,
            cancelled_at: row.get("cancelled_at")?,
            model: row.get("model")?,
            sdk_message_id: row.get("sdk_message_id")?,
            last_assistant_message_id: row.get("last_assistant_message_id")?,
            turn_id: row.get("turn_id")?,
            is_resumable_message: row.get("is_resumable_message")?,
            queue_order: row.get("queue_order")?,
            sender_id: row.get("sender_id")?,
        })
    }
}
