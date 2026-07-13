//
//  TestSupport.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/13/26.
//

import SQLiteData

func testConductorDatabase() throws -> any DatabaseWriter {
    let database = try DatabaseQueue()
    try database.write { database in
        try createTestConductorSchema(in: database)
    }
    return database
}

func createTestConductorSchema(in database: Database) throws {
    try database.execute(
        sql: """
            CREATE TABLE workspaces (
              id TEXT PRIMARY KEY,
              repository_id TEXT,
              directory_name TEXT,
              active_session_id TEXT,
              branch TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              unread INTEGER DEFAULT 0,
              placeholder_branch_name TEXT,
              state TEXT,
              initialization_parent_branch TEXT,
              big_terminal_mode INTEGER,
              setup_log_path TEXT,
              initialization_log_path TEXT,
              initialization_files_copied INTEGER,
              pinned_at TEXT,
              linked_workspace_ids TEXT,
              notes TEXT,
              intended_target_branch TEXT,
              manual_status TEXT,
              derived_status TEXT,
              archive_commit TEXT,
              pr_title TEXT,
              pr_description TEXT,
              secondary_directory_name TEXT,
              linked_directory_paths TEXT,
              hosting_server_url TEXT,
              sandbox_provider TEXT,
              workspace_path TEXT,
              user_set_workspace_name INTEGER,
              user_set_branch_name INTEGER,
              workspace_name TEXT,
              permission_level TEXT,
              creator_user_id TEXT,
              remote_file_sync_enabled INTEGER,
              creator_client_id TEXT,
              organization_id TEXT,
              assignee_user_id TEXT,
              watcher_user_ids TEXT
            );

            CREATE TABLE sessions (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              title TEXT NOT NULL,
              agent_type TEXT NOT NULL,
              is_hidden INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              last_user_message_at TEXT,
              status TEXT NOT NULL,
              model TEXT NOT NULL,
              unread_count INTEGER NOT NULL DEFAULT 0,
              freshly_compacted INTEGER NOT NULL DEFAULT 0,
              context_token_count INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE repos (
              id TEXT PRIMARY KEY,
              remote_url TEXT,
              name TEXT,
              default_branch TEXT,
              root_path TEXT,
              setup_script TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              storage_version INTEGER,
              archive_script TEXT,
              display_order INTEGER,
              run_script TEXT,
              run_script_mode TEXT,
              remote TEXT,
              custom_prompt_code_review TEXT,
              custom_prompt_create_pr TEXT,
              custom_prompt_rename_branch TEXT,
              conductor_config TEXT,
              custom_prompt_general TEXT,
              icon TEXT,
              hidden INTEGER,
              custom_prompt_fix_errors TEXT,
              custom_prompt_resolve_merge_conflicts TEXT,
              file_include_globs TEXT,
              spotlight_testing INTEGER
            );

            CREATE TABLE session_messages (
              id TEXT PRIMARY KEY,
              session_id TEXT,
              role TEXT,
              content TEXT,
              created_at TEXT NOT NULL,
              sent_at TEXT,
              full_message TEXT,
              cancelled_at TEXT,
              model TEXT,
              sdk_message_id TEXT,
              last_assistant_message_id TEXT,
              turn_id TEXT,
              is_resumable_message INTEGER,
              queue_order INTEGER,
              sender_id TEXT
            );
            """
    )
}
