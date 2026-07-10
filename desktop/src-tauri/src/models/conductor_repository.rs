use rusqlite::{Result, Row};
use serde::Serialize;

#[derive(Serialize)]
pub struct ConductorRepository {
    id: String,
    archive_script: Option<String>,
    conductor_config: Option<String>,
    created_at: String,
    custom_prompt_code_review: Option<String>,
    custom_prompt_create_pr: Option<String>,
    custom_prompt_fix_errors: Option<String>,
    custom_prompt_general: Option<String>,
    custom_prompt_rename_branch: Option<String>,
    custom_prompt_resolve_merge_conflicts: Option<String>,
    default_branch: Option<String>,
    display_order: Option<i64>,
    file_include_globs: Option<String>,
    hidden: Option<i64>,
    icon: Option<String>,
    name: Option<String>,
    remote: Option<String>,
    remote_url: Option<String>,
    root_path: Option<String>,
    run_script: Option<String>,
    run_script_mode: Option<String>,
    setup_script: Option<String>,
    spotlight_testing: Option<i64>,
    storage_version: Option<i64>,
    updated_at: String,
}

impl ConductorRepository {
    pub fn load() -> Result<Vec<Self>, String> {
        let connection = crate::open_conductor_db_readonly()?;

        let mut statement = connection
            .prepare(
                r#"
                SELECT
                    id,
                    remote_url,
                    name,
                    default_branch,
                    root_path,
                    setup_script,
                    created_at,
                    updated_at,
                    storage_version,
                    archive_script,
                    display_order,
                    run_script,
                    run_script_mode,
                    remote,
                    custom_prompt_code_review,
                    custom_prompt_create_pr,
                    custom_prompt_rename_branch,
                    conductor_config,
                    custom_prompt_general,
                    icon,
                    hidden,
                    custom_prompt_fix_errors,
                    custom_prompt_resolve_merge_conflicts,
                    file_include_globs,
                    spotlight_testing
                FROM repos
                ORDER BY display_order asc
                "#,
            )
            .map_err(|error| format!("Could not prepare repositories query: {error}"))?;

        let rows = statement
            .query_map([], Self::create_from_row)
            .map_err(|error| format!("Could not query repositories: {error}"))?;

        let mut repositories = Vec::new();

        for row in rows {
            repositories
                .push(row.map_err(|error| format!("Could not read repository row: {error}"))?);
        }

        Ok(repositories)
    }

    pub fn create_from_row(row: &Row<'_>) -> Result<Self> {
        Ok(Self {
            id: row.get("id")?,
            archive_script: row.get("archive_script")?,
            conductor_config: row.get("conductor_config")?,
            created_at: row.get("created_at")?,
            custom_prompt_code_review: row.get("custom_prompt_code_review")?,
            custom_prompt_create_pr: row.get("custom_prompt_create_pr")?,
            custom_prompt_fix_errors: row.get("custom_prompt_fix_errors")?,
            custom_prompt_general: row.get("custom_prompt_general")?,
            custom_prompt_rename_branch: row.get("custom_prompt_rename_branch")?,
            custom_prompt_resolve_merge_conflicts: row
                .get("custom_prompt_resolve_merge_conflicts")?,
            default_branch: row.get("default_branch")?,
            display_order: row.get("display_order")?,
            file_include_globs: row.get("file_include_globs")?,
            hidden: row.get("hidden")?,
            icon: row.get("icon")?,
            name: row.get("name")?,
            remote: row.get("remote")?,
            remote_url: row.get("remote_url")?,
            root_path: row.get("root_path")?,
            run_script: row.get("run_script")?,
            run_script_mode: row.get("run_script_mode")?,
            setup_script: row.get("setup_script")?,
            spotlight_testing: row.get("spotlight_testing")?,
            storage_version: row.get("storage_version")?,
            updated_at: row.get("updated_at")?,
        })
    }
}
