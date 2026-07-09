use rusqlite::{Result, Row};
use serde::Serialize;

#[derive(Serialize)]
pub struct ConductorWorkspace {
    id: String,
    active_session_id: Option<String>,
    archive_commit: Option<String>,
    assignee_user_id: Option<String>,
    big_terminal_mode: Option<i64>,
    branch: Option<String>,
    created_at: String,
    creator_client_id: Option<String>,
    creator_user_id: Option<String>,
    // #[serde(rename = "DEPRECATED_archived")]
    // deprecated_archived: Option<i64>,
    // #[serde(rename = "DEPRECATED_city_name")]
    // deprecated_city_name: Option<String>,
    derived_status: Option<String>,
    directory_name: Option<String>,
    hosting_server_url: Option<String>,
    initialization_files_copied: Option<i64>,
    initialization_log_path: Option<String>,
    initialization_parent_branch: Option<String>,
    intended_target_branch: Option<String>,
    linked_directory_paths: Option<String>,
    linked_workspace_ids: Option<String>,
    manual_status: Option<String>,
    notes: Option<String>,
    organization_id: Option<String>,
    permission_level: Option<String>,
    pinned_at: Option<String>,
    placeholder_branch_name: Option<String>,
    pr_description: Option<String>,
    pr_title: Option<String>,
    remote_file_sync_enabled: Option<i64>,
    repository_id: Option<String>,
    sandbox_provider: Option<String>,
    secondary_directory_name: Option<String>,
    setup_log_path: Option<String>,
    state: Option<String>,
    unread: Option<i64>,
    updated_at: String,
    user_set_branch_name: Option<i64>,
    user_set_workspace_name: Option<i64>,
    watcher_user_ids: Option<String>,
    workspace_name: Option<String>,
    workspace_path: Option<String>,
}

impl ConductorWorkspace {
    pub fn load() -> Result<Vec<Self>, String> {
        let connection = crate::open_conductor_db_readonly()?;

        let mut statement = connection
            .prepare(
                r#"
                SELECT
                    id,
                    repository_id,
                    DEPRECATED_city_name,
                    directory_name,
                    DEPRECATED_archived,
                    active_session_id,
                    branch,
                    created_at,
                    updated_at,
                    unread,
                    placeholder_branch_name,
                    state,
                    initialization_parent_branch,
                    big_terminal_mode,
                    setup_log_path,
                    initialization_log_path,
                    initialization_files_copied,
                    pinned_at,
                    linked_workspace_ids,
                    notes,
                    intended_target_branch,
                    manual_status,
                    derived_status,
                    archive_commit,
                    pr_title,
                    pr_description,
                    secondary_directory_name,
                    linked_directory_paths,
                    hosting_server_url,
                    sandbox_provider,
                    workspace_path,
                    user_set_workspace_name,
                    user_set_branch_name,
                    workspace_name,
                    permission_level,
                    creator_user_id,
                    remote_file_sync_enabled,
                    creator_client_id,
                    organization_id,
                    assignee_user_id,
                    watcher_user_ids
                FROM workspaces
                ORDER BY updated_at desc
                limit 200
                "#,
            )
            .map_err(|error| format!("Could not prepare workspaces query: {error}"))?;

        let rows = statement
            .query_map([], Self::create_from_row)
            .map_err(|error| format!("Could not query workspaces: {error}"))?;

        let mut workspaces = Vec::new();

        for row in rows {
            workspaces.push(row.map_err(|error| format!("Could not read workspace row: {error}"))?);
        }

        Ok(workspaces)
    }

    pub fn create_from_row(row: &Row<'_>) -> Result<Self> {
        Ok(Self {
            id: row.get("id")?,
            active_session_id: row.get("active_session_id")?,
            archive_commit: row.get("archive_commit")?,
            assignee_user_id: row.get("assignee_user_id")?,
            big_terminal_mode: row.get("big_terminal_mode")?,
            branch: row.get("branch")?,
            created_at: row.get("created_at")?,
            creator_client_id: row.get("creator_client_id")?,
            creator_user_id: row.get("creator_user_id")?,
            // deprecated_archived: row.get("DEPRECATED_archived")?,
            // deprecated_city_name: row.get("DEPRECATED_city_name")?,
            derived_status: row.get("derived_status")?,
            directory_name: row.get("directory_name")?,
            hosting_server_url: row.get("hosting_server_url")?,
            initialization_files_copied: row.get("initialization_files_copied")?,
            initialization_log_path: row.get("initialization_log_path")?,
            initialization_parent_branch: row.get("initialization_parent_branch")?,
            intended_target_branch: row.get("intended_target_branch")?,
            linked_directory_paths: row.get("linked_directory_paths")?,
            linked_workspace_ids: row.get("linked_workspace_ids")?,
            manual_status: row.get("manual_status")?,
            notes: row.get("notes")?,
            organization_id: row.get("organization_id")?,
            permission_level: row.get("permission_level")?,
            pinned_at: row.get("pinned_at")?,
            placeholder_branch_name: row.get("placeholder_branch_name")?,
            pr_description: row.get("pr_description")?,
            pr_title: row.get("pr_title")?,
            remote_file_sync_enabled: row.get("remote_file_sync_enabled")?,
            repository_id: row.get("repository_id")?,
            sandbox_provider: row.get("sandbox_provider")?,
            secondary_directory_name: row.get("secondary_directory_name")?,
            setup_log_path: row.get("setup_log_path")?,
            state: row.get("state")?,
            unread: row.get("unread")?,
            updated_at: row.get("updated_at")?,
            user_set_branch_name: row.get("user_set_branch_name")?,
            user_set_workspace_name: row.get("user_set_workspace_name")?,
            watcher_user_ids: row.get("watcher_user_ids")?,
            workspace_name: row.get("workspace_name")?,
            workspace_path: row.get("workspace_path")?,
        })
    }
}
