import Dependencies
import SQLiteData

public func appDatabase() throws -> any DatabaseWriter {
    let database = try SQLiteData.defaultDatabase()
    var migrator = DatabaseMigrator()

    #if DEBUG
    migrator.eraseDatabaseOnSchemaChange = true
    #endif
    
    migrator.registerMigration("Create workspaces") { db in
        try #sql(
            """
            CREATE TABLE "workspaces" (
              "id" TEXT PRIMARY KEY,
              "repository_id" TEXT,
              "DEPRECATED_city_name" TEXT,
              "directory_name" TEXT,
              "DEPRECATED_archived" INTEGER DEFAULT 0,
              "active_session_id" TEXT,
              "branch" TEXT,
              "created_at" TEXT NOT NULL DEFAULT (datetime('now')),
              "updated_at" TEXT NOT NULL DEFAULT (datetime('now')),
              "unread" INTEGER DEFAULT 0,
              "placeholder_branch_name" TEXT,
              "state" TEXT DEFAULT 'active',
              "initialization_parent_branch" TEXT,
              "big_terminal_mode" INTEGER DEFAULT 0,
              "setup_log_path" TEXT,
              "initialization_log_path" TEXT,
              "initialization_files_copied" INTEGER,
              "pinned_at" TEXT,
              "linked_workspace_ids" TEXT,
              "notes" TEXT,
              "intended_target_branch" TEXT,
              "manual_status" TEXT,
              "derived_status" TEXT DEFAULT 'in-progress',
              "archive_commit" TEXT,
              "pr_title" TEXT,
              "pr_description" TEXT,
              "secondary_directory_name" TEXT,
              "linked_directory_paths" TEXT,
              "hosting_server_url" TEXT,
              "sandbox_provider" TEXT,
              "workspace_path" TEXT,
              "user_set_workspace_name" INTEGER DEFAULT 0,
              "user_set_branch_name" INTEGER DEFAULT 0,
              "workspace_name" TEXT,
              "permission_level" TEXT,
              "creator_user_id" TEXT,
              "remote_file_sync_enabled" INTEGER DEFAULT 0,
              "creator_client_id" TEXT,
              "organization_id" TEXT,
              "assignee_user_id" TEXT,
              "watcher_user_ids" TEXT
            );
            """
        )
        .execute(db)
    }

    migrator.registerMigration("Create sessions") { db in
        try #sql(
            """
            CREATE TABLE "sessions" (
              "id" TEXT PRIMARY KEY,
              "workspace_id" TEXT NOT NULL,
              "title" TEXT NOT NULL,
              "agent_type" TEXT NOT NULL,
              "created_at" TEXT NOT NULL,
              "updated_at" TEXT NOT NULL,
              "last_user_message_at" TEXT,
              "status" TEXT NOT NULL,
              "model" TEXT NOT NULL,
              "unread_count" INTEGER NOT NULL DEFAULT 0,
              "freshly_compacted" INTEGER NOT NULL DEFAULT 0,
              "context_token_count" INTEGER NOT NULL DEFAULT 0
            );
            """
        )
        .execute(db)
        try #sql(
            """
            CREATE INDEX "sessions_workspace_id_updated_at"
            ON "sessions" ("workspace_id", "updated_at" DESC);
            """
        )
        .execute(db)
    }

    migrator.registerMigration("Create repos") { db in
        try #sql(
            """
            CREATE TABLE "repos" (
              "id" TEXT PRIMARY KEY,
              "remote_url" TEXT,
              "name" TEXT,
              "default_branch" TEXT DEFAULT 'main',
              "root_path" TEXT,
              "setup_script" TEXT,
              "created_at" TEXT NOT NULL DEFAULT (datetime('now')),
              "updated_at" TEXT NOT NULL DEFAULT (datetime('now')),
              "storage_version" INTEGER DEFAULT 1,
              "archive_script" TEXT,
              "display_order" INTEGER DEFAULT 0,
              "run_script" TEXT,
              "run_script_mode" TEXT DEFAULT 'concurrent',
              "remote" TEXT,
              "custom_prompt_code_review" TEXT,
              "custom_prompt_create_pr" TEXT,
              "custom_prompt_rename_branch" TEXT,
              "conductor_config" TEXT,
              "custom_prompt_general" TEXT,
              "icon" TEXT,
              "hidden" INTEGER DEFAULT 0,
              "custom_prompt_fix_errors" TEXT,
              "custom_prompt_resolve_merge_conflicts" TEXT,
              "file_include_globs" TEXT,
              "spotlight_testing" INTEGER DEFAULT 0
            );
            """
        )
        .execute(db)
    }

    try migrator.migrate(database)
    return database
}

public extension DependencyValues {
    mutating func bootstrapDatabase() throws {
        defaultDatabase = try appDatabase()
    }
}
