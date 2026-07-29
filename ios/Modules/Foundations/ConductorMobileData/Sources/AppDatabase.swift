//
//  AppDatabase.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import Dependencies
import SQLiteData

public func appDatabase() throws -> any DatabaseWriter {
    let database = try SQLiteData.defaultDatabase()
    let migrator = appDatabaseMigrator()
    try migrator.migrate(database)
    return database
}

func appDatabaseMigrator() -> DatabaseMigrator {
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
              "is_hidden" INTEGER NOT NULL DEFAULT 0,
              "created_at" TEXT NOT NULL,
              "updated_at" TEXT NOT NULL,
              "last_user_message_at" TEXT,
              "status" TEXT NOT NULL,
              "model" TEXT NOT NULL,
              "fast_mode" INTEGER DEFAULT 0,
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

    migrator.registerMigration("Add session queue pause") { db in
        try #sql(
            """
            ALTER TABLE "sessions"
            ADD COLUMN "queue_paused_at" TEXT;
            """
        )
        .execute(db)
    }

    migrator.registerMigration("Add session reasoning effort") { db in
        try #sql("ALTER TABLE \"sessions\" ADD COLUMN \"codex_thinking_level\" TEXT")
            .execute(db)
        try #sql("ALTER TABLE \"sessions\" ADD COLUMN \"claude_effort_level\" TEXT")
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

    migrator.registerMigration("Create session messages") { db in
        try #sql(
            """
            CREATE TABLE "session_messages" (
              "id" TEXT PRIMARY KEY,
              "session_id" TEXT,
              "role" TEXT,
              "content" TEXT,
              "created_at" TEXT NOT NULL DEFAULT (datetime('now')),
              "sent_at" TEXT,
              "full_message" TEXT,
              "cancelled_at" TEXT,
              "model" TEXT,
              "sdk_message_id" TEXT,
              "last_assistant_message_id" TEXT,
              "turn_id" TEXT,
              "is_resumable_message" INTEGER,
              "queue_order" INTEGER,
              "sender_id" TEXT
            );
            """
        )
        .execute(db)
        try #sql(
            """
            CREATE INDEX "session_messages_session_id_created_at"
            ON "session_messages" ("session_id", "created_at");
            """
        )
        .execute(db)
    }

    migrator.registerMigration("Create mobile workspace state") { db in
        try #sql(
            // REFERENCES creates the foreign key; CASCADE removes state with its workspace.
            """
            CREATE TABLE "mobile_workspace_state" (
              "id" TEXT PRIMARY KEY REFERENCES "workspaces" ("id") ON DELETE CASCADE,
              "is_working" INTEGER NOT NULL DEFAULT 0,
              "pull_request_url" TEXT,
              "pull_request_is_draft" INTEGER NOT NULL DEFAULT 0,
              "pull_request_is_merged" INTEGER NOT NULL DEFAULT 0,
              "pull_request_merge_state_status" TEXT,
              "pull_request_checks_status" TEXT
            );
            """
        )
        .execute(db)
    }

    migrator.registerMigration("Create cloud workspace metadata") { db in
        try #sql(
            """
            CREATE TABLE "cloud_workspace_metadata" (
              "workspace_id" TEXT PRIMARY KEY
                REFERENCES "workspaces" ("id") ON DELETE CASCADE,
              "account_id" TEXT NOT NULL,
              "last_seen_generation" TEXT NOT NULL
            );
            """
        )
        .execute(db)
        try #sql(
            """
            CREATE INDEX "cloud_workspace_metadata_account_id"
            ON "cloud_workspace_metadata" ("account_id");
            """
        )
        .execute(db)
    }

    migrator.registerMigration("Allow null session titles") { db in
        try #sql(
            """
            CREATE TABLE "sessions_with_nullable_title" (
              "id" TEXT PRIMARY KEY,
              "workspace_id" TEXT NOT NULL,
              "title" TEXT,
              "agent_type" TEXT NOT NULL,
              "is_hidden" INTEGER NOT NULL DEFAULT 0,
              "created_at" TEXT NOT NULL,
              "updated_at" TEXT NOT NULL,
              "last_user_message_at" TEXT,
              "status" TEXT NOT NULL,
              "model" TEXT NOT NULL,
              "queue_paused_at" TEXT,
              "codex_thinking_level" TEXT,
              "fast_mode" INTEGER DEFAULT 0,
              "claude_effort_level" TEXT,
              "unread_count" INTEGER NOT NULL DEFAULT 0,
              "freshly_compacted" INTEGER NOT NULL DEFAULT 0,
              "context_token_count" INTEGER NOT NULL DEFAULT 0
            );
            """
        )
        .execute(db)
        try #sql(
            """
            INSERT INTO "sessions_with_nullable_title" (
              "id",
              "workspace_id",
              "title",
              "agent_type",
              "is_hidden",
              "created_at",
              "updated_at",
              "last_user_message_at",
              "status",
              "model",
              "queue_paused_at",
              "codex_thinking_level",
              "fast_mode",
              "claude_effort_level",
              "unread_count",
              "freshly_compacted",
              "context_token_count"
            )
            SELECT
              "id",
              "workspace_id",
              "title",
              "agent_type",
              "is_hidden",
              "created_at",
              "updated_at",
              "last_user_message_at",
              "status",
              "model",
              "queue_paused_at",
              "codex_thinking_level",
              "fast_mode",
              "claude_effort_level",
              "unread_count",
              "freshly_compacted",
              "context_token_count"
            FROM "sessions";
            """
        )
        .execute(db)
        try #sql("DROP TABLE \"sessions\"")
            .execute(db)
        try #sql(
            """
            ALTER TABLE "sessions_with_nullable_title"
            RENAME TO "sessions";
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

    migrator.registerMigration("Create cloud chat metadata") { db in
        try #sql(
            """
            CREATE TABLE "cloud_session_metadata" (
              "canonical_session_id" TEXT PRIMARY KEY
                REFERENCES "sessions" ("id") ON DELETE CASCADE,
              "cloud_session_id" TEXT NOT NULL,
              "workspace_id" TEXT NOT NULL,
              "account_id" TEXT NOT NULL,
              "list_order" INTEGER NOT NULL,
              "refresh_generation" TEXT NOT NULL
            );
            """
        )
        .execute(db)
        try #sql(
            """
            CREATE UNIQUE INDEX "cloud_session_metadata_account_remote"
            ON "cloud_session_metadata" ("account_id", "cloud_session_id");
            """
        )
        .execute(db)
        try #sql(
            """
            CREATE INDEX "cloud_session_metadata_workspace_order"
            ON "cloud_session_metadata" ("workspace_id", "list_order");
            """
        )
        .execute(db)

        try #sql(
            """
            CREATE TABLE "cloud_message_metadata" (
              "canonical_message_id" TEXT PRIMARY KEY
                REFERENCES "session_messages" ("id") ON DELETE CASCADE,
              "cloud_event_id" TEXT NOT NULL,
              "canonical_session_id" TEXT NOT NULL
                REFERENCES "sessions" ("id") ON DELETE CASCADE,
              "session_index" REAL NOT NULL,
              "adapter_part_order" INTEGER NOT NULL,
              "account_id" TEXT NOT NULL
            );
            """
        )
        .execute(db)
        try #sql(
            """
            CREATE INDEX "cloud_message_metadata_session_order"
            ON "cloud_message_metadata" (
              "canonical_session_id",
              "session_index",
              "adapter_part_order"
            );
            """
        )
        .execute(db)
        try #sql(
            """
            CREATE INDEX "cloud_message_metadata_account_event"
            ON "cloud_message_metadata" ("account_id", "cloud_event_id");
            """
        )
        .execute(db)
    }

    migrator.registerMigration("Add cloud transcript checkpoint") { db in
        try #sql(
            """
            ALTER TABLE "cloud_session_metadata"
            ADD COLUMN "transcript_cursor" TEXT;
            """
        )
        .execute(db)
        try #sql(
            """
            ALTER TABLE "cloud_session_metadata"
            ADD COLUMN "has_complete_transcript" INTEGER NOT NULL DEFAULT 0;
            """
        )
        .execute(db)
        try #sql(
            """
            ALTER TABLE "cloud_session_metadata"
            ADD COLUMN "transcript_projection_version" INTEGER NOT NULL DEFAULT 0;
            """
        )
            .execute(db)
    }

    migrator.registerMigration("Add Cloud remote IDs and transcript refresh") { db in
        try #sql(
            """
            ALTER TABLE "cloud_workspace_metadata"
            ADD COLUMN "remote_workspace_id" TEXT;
            """
        )
        .execute(db)
        try #sql(
            """
            UPDATE "cloud_workspace_metadata"
            SET "remote_workspace_id" = "workspace_id";
            """
        )
        .execute(db)
        try #sql(
            """
            ALTER TABLE "cloud_session_metadata"
            ADD COLUMN "last_full_transcript_refresh_at" TEXT;
            """
        )
        .execute(db)
    }

    migrator.registerMigration("Create Cloud mutation ledger") { db in
        try #sql(
            """
            CREATE TABLE "cloud_pending_mutations" (
              "attempt_id" TEXT PRIMARY KEY,
              "account_id" TEXT NOT NULL,
              "credential_generation" TEXT NOT NULL,
              "operation" TEXT NOT NULL,
              "resource_kind" TEXT NOT NULL,
              "request_version" INTEGER NOT NULL,
              "request_payload" BLOB NOT NULL,
              "rollback_payload" BLOB,
              "canonical_workspace_id" TEXT,
              "remote_workspace_id" TEXT,
              "canonical_session_id" TEXT,
              "remote_session_id" TEXT,
              "canonical_message_id" TEXT,
              "stable_remote_message_id" TEXT,
              "state" TEXT NOT NULL,
              "dispatch_started_at" TEXT,
              "created_at" TEXT NOT NULL,
              "last_transition_at" TEXT NOT NULL
            );
            """
        )
        .execute(db)
        try #sql(
            """
            CREATE INDEX "cloud_pending_mutations_state_created"
            ON "cloud_pending_mutations" ("state", "created_at");
            """
        )
        .execute(db)
        try #sql(
            """
            CREATE INDEX "cloud_pending_mutations_account_generation"
            ON "cloud_pending_mutations" (
              "account_id",
              "credential_generation"
            );
            """
        )
        .execute(db)
        try #sql(
            """
            CREATE TABLE "cloud_mutation_outcomes" (
              "outcome_id" TEXT PRIMARY KEY,
              "attempt_id" TEXT NOT NULL,
              "account_id" TEXT NOT NULL,
              "credential_generation" TEXT NOT NULL,
              "owning_feature" TEXT NOT NULL,
              "kind" TEXT NOT NULL,
              "version" INTEGER NOT NULL,
              "payload" BLOB NOT NULL,
              "created_at" TEXT NOT NULL,
              "consumed_at" TEXT
            );
            """
        )
        .execute(db)
        try #sql(
            """
            CREATE INDEX "cloud_mutation_outcomes_owner_consumed"
            ON "cloud_mutation_outcomes" (
              "owning_feature",
              "consumed_at"
            );
            """
        )
        .execute(db)
    }

    migrator.registerMigration("Create Cloud project repository mappings") { db in
        try #sql(
            """
            CREATE TABLE "cloud_project_repository_mappings" (
              "id" TEXT PRIMARY KEY,
              "account_id" TEXT NOT NULL,
              "cloud_project_id" TEXT NOT NULL,
              "canonical_repository_id" TEXT NOT NULL
                REFERENCES "repos" ("id"),
              "project_name" TEXT NOT NULL,
              "git_remote" TEXT NOT NULL,
              "refresh_generation" TEXT NOT NULL,
              UNIQUE ("account_id", "cloud_project_id")
            );
            """
        )
        .execute(db)
        try #sql(
            """
            CREATE INDEX "cloud_project_repository_mappings_account_generation"
            ON "cloud_project_repository_mappings" (
              "account_id",
              "refresh_generation"
            );
            """
        )
        .execute(db)
    }

    migrator.registerMigration("Create initial prompt handoffs") { db in
        try #sql(
            """
            CREATE TABLE "initial_prompt_handoffs" (
              "handoff_id" TEXT PRIMARY KEY,
              "creation_attempt_id" TEXT NOT NULL,
              "account_id" TEXT NOT NULL,
              "credential_generation" TEXT NOT NULL,
              "canonical_workspace_id" TEXT NOT NULL,
              "remote_workspace_id" TEXT NOT NULL,
              "canonical_session_id" TEXT NOT NULL,
              "remote_session_id" TEXT NOT NULL,
              "original_prompt" TEXT NOT NULL,
              "stable_remote_message_id" TEXT NOT NULL,
              "send_attempt_id" TEXT,
              "installed_draft_text" TEXT,
              "state" TEXT NOT NULL,
              "created_at" TEXT NOT NULL,
              "last_transition_at" TEXT NOT NULL
            );
            """
        )
        .execute(db)
        try #sql(
            """
            CREATE INDEX "initial_prompt_handoffs_session_state"
            ON "initial_prompt_handoffs" (
              "canonical_session_id",
              "state"
            );
            """
        )
        .execute(db)
        try #sql(
            """
            CREATE UNIQUE INDEX "initial_prompt_handoffs_send_attempt"
            ON "initial_prompt_handoffs" ("send_attempt_id")
            WHERE "send_attempt_id" IS NOT NULL;
            """
        )
        .execute(db)
    }

    // A metadata row is the durable marker that one session has a complete transcript baseline.
    // Its nullable cursor distinguishes complete empty history from a missing, unusable baseline.
    migrator.registerMigration("Create desktop transcript sync metadata") { db in
        try #sql(
            """
            CREATE TABLE "desktop_transcript_metadata" (
              "session_id" TEXT PRIMARY KEY
                REFERENCES "sessions" ("id") ON DELETE CASCADE,
              "transcript_cursor" TEXT,
              CHECK (
                "transcript_cursor" IS NULL
                OR length(CAST("transcript_cursor" AS BLOB)) >= 1
              )
            );
            """
        )
        .execute(db)
    }

    migrator.registerMigration("Create unified message delivery outbox") { db in
        try #sql(
            """
            CREATE TABLE "message_delivery_attempts" (
              "attempt_id" TEXT PRIMARY KEY,
              "route" TEXT NOT NULL,
              "account_id" TEXT,
              "credential_generation" TEXT,
              "desktop_endpoint" TEXT,
              "cloud_delivery_state" TEXT,
              "canonical_workspace_id" TEXT NOT NULL,
              "remote_workspace_id" TEXT,
              "canonical_session_id" TEXT NOT NULL,
              "remote_session_id" TEXT,
              "content" TEXT NOT NULL,
              "model" TEXT NOT NULL,
              "is_fast_mode_enabled" INTEGER NOT NULL,
              "mode" TEXT NOT NULL,
              "reasoning_effort" TEXT,
              "submitted_draft" TEXT NOT NULL,
              "previous_turn_id" TEXT,
              "state" TEXT NOT NULL,
              "result_detail" TEXT,
              "canonical_message_id" TEXT,
              "canonical_turn_id" TEXT,
              "dispatch_started_at" TEXT,
              "result_presented_at" TEXT,
              "created_at" TEXT NOT NULL,
              "last_transition_at" TEXT NOT NULL,
              "acknowledged_at" TEXT
            );
            """
        )
        .execute(db)
        try #sql(
            """
            CREATE INDEX "message_delivery_attempts_state_created"
            ON "message_delivery_attempts" ("state", "created_at");
            """
        )
        .execute(db)
        try #sql(
            """
            CREATE INDEX "message_delivery_attempts_session_created"
            ON "message_delivery_attempts" (
              "canonical_session_id",
              "created_at"
            );
            """
        )
        .execute(db)
        try #sql(
            """
            CREATE INDEX "message_delivery_attempts_account_generation"
            ON "message_delivery_attempts" (
              "account_id",
              "credential_generation"
            );
            """
        )
        .execute(db)

        try #sql(
            """
            INSERT OR IGNORE INTO "message_delivery_attempts" (
              "attempt_id",
              "route",
              "account_id",
              "credential_generation",
              "desktop_endpoint",
              "cloud_delivery_state",
              "canonical_workspace_id",
              "remote_workspace_id",
              "canonical_session_id",
              "remote_session_id",
              "content",
              "model",
              "is_fast_mode_enabled",
              "mode",
              "reasoning_effort",
              "submitted_draft",
              "previous_turn_id",
              "state",
              "result_detail",
              "canonical_message_id",
              "canonical_turn_id",
              "dispatch_started_at",
              "result_presented_at",
              "created_at",
              "last_transition_at",
              "acknowledged_at"
            )
            SELECT
              COALESCE("stable_remote_message_id", "attempt_id"),
              'cloud',
              "account_id",
              "credential_generation",
              NULL,
              NULL,
              COALESCE("canonical_workspace_id", ''),
              "remote_workspace_id",
              COALESCE("canonical_session_id", ''),
              "remote_session_id",
              COALESCE(
                json_extract(CAST("request_payload" AS TEXT), '$.message'),
                ''
              ),
              '',
              0,
              'sent',
              NULL,
              COALESCE(
                json_extract(
                  CAST("rollback_payload" AS TEXT),
                  '$.submittedDraft'
                ),
                json_extract(CAST("request_payload" AS TEXT), '$.message'),
                ''
              ),
              NULL,
              CASE
                WHEN "state" = 'submitting'
                  AND "dispatch_started_at" IS NULL THEN 'ready'
                WHEN "state" = 'accepted' THEN 'accepted'
                ELSE 'unknown'
              END,
              CASE
                WHEN "state" = 'submitting'
                  AND "dispatch_started_at" IS NULL THEN NULL
                WHEN "state" = 'accepted' THEN NULL
                ELSE 'Delivery could not be determined before migration.'
              END,
              "canonical_message_id",
              NULL,
              "dispatch_started_at",
              NULL,
              "created_at",
              "last_transition_at",
              NULL
            FROM "cloud_pending_mutations"
            WHERE "operation" = 'send-message'
              AND "state" != 'acknowledged';
            """
        )
        .execute(db)

        try #sql(
            """
            INSERT OR IGNORE INTO "message_delivery_attempts" (
              "attempt_id",
              "route",
              "account_id",
              "credential_generation",
              "desktop_endpoint",
              "cloud_delivery_state",
              "canonical_workspace_id",
              "remote_workspace_id",
              "canonical_session_id",
              "remote_session_id",
              "content",
              "model",
              "is_fast_mode_enabled",
              "mode",
              "reasoning_effort",
              "submitted_draft",
              "previous_turn_id",
              "state",
              "result_detail",
              "canonical_message_id",
              "canonical_turn_id",
              "dispatch_started_at",
              "result_presented_at",
              "created_at",
              "last_transition_at",
              "acknowledged_at"
            )
            SELECT
              "handoff"."stable_remote_message_id",
              'cloud',
              "handoff"."account_id",
              "handoff"."credential_generation",
              NULL,
              NULL,
              "handoff"."canonical_workspace_id",
              "handoff"."remote_workspace_id",
              "handoff"."canonical_session_id",
              "handoff"."remote_session_id",
              "handoff"."original_prompt",
              '',
              0,
              'sent',
              NULL,
              COALESCE(
                "handoff"."installed_draft_text",
                "handoff"."original_prompt"
              ),
              NULL,
              CASE
                WHEN "handoff"."state" = 'ready' THEN 'ready'
                WHEN "outcome"."outcome_id" IS NOT NULL THEN 'rejected'
                ELSE 'unknown'
              END,
              CASE
                WHEN "handoff"."state" = 'ready' THEN NULL
                WHEN "outcome"."outcome_id" IS NOT NULL
                  THEN 'Cloud rejected this message before migration.'
                ELSE 'Delivery could not be determined before migration.'
              END,
              NULL,
              NULL,
              NULL,
              NULL,
              "handoff"."created_at",
              "handoff"."last_transition_at",
              NULL
            FROM "initial_prompt_handoffs" AS "handoff"
            LEFT JOIN "cloud_pending_mutations" AS "mutation"
              ON "mutation"."attempt_id" = "handoff"."send_attempt_id"
            LEFT JOIN "cloud_mutation_outcomes" AS "outcome"
              ON "outcome"."attempt_id" = "handoff"."send_attempt_id"
              AND "outcome"."kind" = 'rejected-mutation'
            WHERE "handoff"."state" = 'ready'
              OR (
                "handoff"."state" = 'linked'
                AND "mutation"."attempt_id" IS NULL
              );
            """
        )
        .execute(db)

        try #sql(
            """
            DELETE FROM "cloud_mutation_outcomes"
            WHERE "attempt_id" IN (
              SELECT "attempt_id"
              FROM "cloud_pending_mutations"
              WHERE "operation" = 'send-message'
              UNION
              SELECT "send_attempt_id"
              FROM "initial_prompt_handoffs"
              WHERE "send_attempt_id" IS NOT NULL
            );
            """
        )
        .execute(db)
        try #sql(
            """
            DELETE FROM "cloud_pending_mutations"
            WHERE "operation" = 'send-message';
            """
        )
        .execute(db)
        try #sql("DROP TABLE \"initial_prompt_handoffs\"")
            .execute(db)
    }

    return migrator
}

public extension DependencyValues {
    mutating func bootstrapDatabase() throws {
        defaultDatabase = try appDatabase()
    }
}
