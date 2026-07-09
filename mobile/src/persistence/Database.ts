import { SQLiteProvider, type SQLiteDatabase } from "expo-sqlite";

type Workspace = {
  id: string;
  workspace_id: string;
  title: string;
  agent_type: string;

  created_at: string;
  updated_at: string;
  last_user_message_at: string | null;

  status: string;
  model: string;

  unread_count: number;
  freshly_compacted: number;
  context_token_count: number;
}

async function migrateDbIfNeeded(db: SQLiteDatabase) {
  const result = await db.getFirstAsync<{user_version: number}>
}

function createReposTable(): string {
  return `
    CREATE TABLE repos (
      id TEXT PRIMARY KEY,
      remote_url TEXT,
      name TEXT,
      default_branch TEXT DEFAULT 'main',
      root_path TEXT,
      setup_script TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      storage_version INTEGER DEFAULT 1,
      archive_script TEXT,
      display_order INTEGER DEFAULT 0,
      run_script TEXT,
      run_script_mode TEXT DEFAULT 'concurrent',
      remote TEXT,
      custom_prompt_code_review TEXT,
      custom_prompt_create_pr TEXT,
      custom_prompt_rename_branch TEXT,
      conductor_config TEXT,
      custom_prompt_general TEXT,
      icon TEXT,
      hidden INTEGER DEFAULT 0,
      custom_prompt_fix_errors TEXT,
      custom_prompt_resolve_merge_conflicts TEXT,
      file_include_globs TEXT,
      spotlight_testing INTEGER DEFAULT 0
    );
  `;
}

function createWorkspaceTable(): string {
  return `
    CREATE TABLE workspaces (
      id TEXT PRIMARY KEY,
      repository_id TEXT,
      DEPRECATED_city_name TEXT,
      directory_name TEXT,
      DEPRECATED_archived INTEGER DEFAULT 0,
      active_session_id TEXT,
      branch TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      unread INTEGER DEFAULT 0,
      placeholder_branch_name TEXT,
      state TEXT DEFAULT 'active',
      initialization_parent_branch TEXT,
      big_terminal_mode INTEGER DEFAULT 0,
      setup_log_path TEXT,
      initialization_log_path TEXT,
      initialization_files_copied INTEGER,
      pinned_at TEXT,
      linked_workspace_ids TEXT,
      notes TEXT,
      intended_target_branch TEXT,
      manual_status TEXT,
      derived_status TEXT DEFAULT 'in-progress',
      archive_commit TEXT,
      pr_title TEXT,
      pr_description TEXT,
      secondary_directory_name TEXT,
      linked_directory_paths TEXT,
      hosting_server_url TEXT,
      sandbox_provider TEXT,
      workspace_path TEXT,
      user_set_workspace_name INTEGER DEFAULT 0,
      user_set_branch_name INTEGER DEFAULT 0,
      workspace_name TEXT,
      permission_level TEXT,
      creator_user_id TEXT,
      remote_file_sync_enabled INTEGER DEFAULT 0,
      creator_client_id TEXT,
      organization_id TEXT,
      assignee_user_id TEXT,
      watcher_user_ids TEXT
    );
    `
}

function createSessionsTable(): string {
  return `
    CREATE TABLE "sessions" (
      id TEXT PRIMARY KEY,
      status TEXT DEFAULT 'idle',
      claude_session_id TEXT,
      unread_count INTEGER DEFAULT 0,
      freshly_compacted INTEGER DEFAULT 0,
      context_token_count INTEGER DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      is_compacting INTEGER DEFAULT 0,
      model TEXT,
      permission_mode TEXT DEFAULT 'default',
      DEPRECATED_thinking_level TEXT DEFAULT 'NONE',
      last_user_message_at TEXT,
      resume_session_at TEXT,
      workspace_id TEXT,
      is_hidden INTEGER DEFAULT 0,
      agent_type,
      title TEXT DEFAULT 'Untitled',
      context_used_percent FLOAT,
      DEPRECATED_thinking_enabled INTEGER DEFAULT 1,
      codex_thinking_level TEXT,
      fast_mode INTEGER DEFAULT 0,
      agent_personality TEXT,
      claude_effort_level TEXT,
      feed_offset INTEGER,
      queue_paused_at TEXT
    );
  `
}

function createSessionMessagesTable(): string {
  return `
    CREATE TABLE session_messages (
      id TEXT PRIMARY KEY,
      session_id TEXT,
      role TEXT,
      content TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
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
  `;
}