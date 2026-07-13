//
//  ServerTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Dependencies
import Foundation
import HummingbirdTesting
import NIOCore
import SharedConductorData
import SQLiteData
import Testing

@testable import ConductorMobileServer

struct ServerTests {
    @Test("Mobile routes keep the existing paths and JSON contract")
    func routes() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let iconData = Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        try iconData.write(to: rootURL.appending(path: "favicon.png"))

        let database = try testConductorDatabase()
        try await database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO workspaces (id, created_at, updated_at)
                    VALUES
                      ('workspace-sqlite', '2026-07-09 00:00:01.125', '2026-07-09 00:00:01.125'),
                      ('workspace-iso', '2026-07-09T00:00:02Z', '2026-07-09T00:00:02Z')
                    """
            )
        }
        let application = Server.makeApplication(database: database)

        try await application.test(.router) { client in
            for uri in [
                "/sessions",
                "/repositories",
                "/workspaces/workspace-1/sessions",
                "/workspaces/workspace-1/sessions/session-1/messages",
            ] {
                try await client.execute(uri: uri, method: .get) { response in
                    #expect(response.status == .ok)
                    #expect(String(buffer: response.body) == "[]")
                }
            }

            try await database.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO sessions (
                          id, workspace_id, title, agent_type, created_at, updated_at, status, model
                        ) VALUES (
                          'session-1', 'workspace-iso', 'Working', 'codex',
                          '2026-07-09 00:00:01', '2026-07-09 00:00:01', 'working', 'gpt-5'
                        );

                        INSERT INTO session_messages (
                          id, session_id, role, content, created_at, sent_at
                        ) VALUES (
                          'message-1', 'session-1', 'assistant', 'Ready.',
                          '2026-07-09T00:00:02Z', '2026-07-09T00:00:03Z'
                        );

                        INSERT INTO repos (id, root_path, created_at, updated_at)
                        VALUES (
                          'repository-1', ?, '2026-07-09T00:00:02Z', '2026-07-09T00:00:03Z'
                        );
                        """,
                    arguments: [rootURL.path]
                )
            }

            try await client.execute(uri: "/workspaces", method: .get) { response in
                #expect(response.status == .ok)
                let object = try #require(
                    JSONSerialization.jsonObject(
                        with: Data(response.body.readableBytesView)
                    ) as? [[String: Any]]
                )
                #expect(object.count == 2)
                let sqliteWorkspace = try #require(
                    object.first { $0["id"] as? String == "workspace-sqlite" }
                )
                #expect(sqliteWorkspace["createdAt"] == nil)
                #expect((sqliteWorkspace["created_at"] as? String)?.hasSuffix(".125Z") == true)

                let isoWorkspace = try #require(
                    object.first { $0["id"] as? String == "workspace-iso" }
                )
                #expect((isoWorkspace["created_at"] as? String)?.hasSuffix(".000Z") == true)
                #expect(isoWorkspace["is_working"] as? Bool == true)
            }

            try await client.execute(
                uri: "/workspaces/workspace-iso/sessions/session-1/messages",
                method: .get
            ) { response in
                #expect(response.status == .ok)
                let object = try #require(
                    JSONSerialization.jsonObject(
                        with: Data(response.body.readableBytesView)
                    ) as? [[String: Any]]
                )
                #expect(object.first?["id"] as? String == "message-1")
                #expect((object.first?["created_at"] as? String)?.hasSuffix(".000Z") == true)
            }

            try await client.execute(uri: "/repositories", method: .get) { response in
                #expect(response.status == .ok)
                let object = try #require(
                    JSONSerialization.jsonObject(
                        with: Data(response.body.readableBytesView)
                    ) as? [[String: Any]]
                )
                #expect(object.first?["id"] as? String == "repository-1")
                #expect((object.first?["created_at"] as? String)?.hasSuffix(".000Z") == true)
            }

            try await client.execute(
                uri: "/repositories/repository-1/icon",
                method: .get
            ) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "image/png")
                #expect(response.headers[.eTag] != nil)
                #expect(Data(response.body.readableBytesView) == iconData)
            }
        }
    }

    @Test("POST message forwards the selected session to the sidecar bridge")
    func postMessage() async throws {
        let database = try testConductorDatabase()
        let date = Date(timeIntervalSince1970: 1_783_555_200)
        let workspace = Workspace(
            id: "workspace-1",
            createdAt: date,
            updatedAt: date,
            workspacePath: "/tmp/workspace-1"
        )
        let session = Session(
            id: "session-1",
            workspaceID: workspace.id,
            title: "Working",
            agentType: .codex,
            isHidden: false,
            createdAt: "2026-07-09T00:00:01Z",
            updatedAt: "2026-07-09T00:00:01Z",
            lastUserMessageAt: nil,
            status: .idle,
            model: "gpt-5.5",
            unreadCount: 0,
            freshlyCompacted: 0,
            contextTokenCount: 0
        )
        try await database.write { db in
            try Workspace.insert { workspace }.execute(db)
            try Session.insert { session }.execute(db)
        }
        let recorder = MessageRecorder()
        try await withDependencies {
            $0.sidecarBridgeClient.sendMessage = { message in
                await recorder.record(message)
            }
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/workspace-1/sessions/session-1/messages",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(string: #"{"message":"  Run the tests.  "}"#)
                ) { response in
                    #expect(response.status == .noContent)
                    #expect(response.body.readableBytes == 0)
                }
            }
        }

        #expect(
            await recorder.message == SidecarBridgeClient.RuntimeMessageRequest(
                agentType: "codex",
                cwd: "/tmp/workspace-1",
                message: "  Run the tests.  ",
                model: "gpt-5.5",
                sessionID: "session-1",
                workspaceID: "workspace-1"
            )
        )
    }

    @Test("POST message rejects blank input before contacting the sidecar bridge")
    func postBlankMessage() async throws {
        let database = try testConductorDatabase()
        let recorder = MessageRecorder()
        try await withDependencies {
            $0.sidecarBridgeClient.sendMessage = { message in
                await recorder.record(message)
            }
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/workspace-1/sessions/session-1/messages",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(string: #"{"message":" \n "}"#)
                ) { response in
                    #expect(response.status == .badRequest)
                    #expect(String(buffer: response.body) == "Message cannot be empty.")
                }
            }
        }

        #expect(await recorder.message == nil)
    }
}

private actor MessageRecorder {
    private(set) var message: SidecarBridgeClient.RuntimeMessageRequest?

    func record(_ message: SidecarBridgeClient.RuntimeMessageRequest) {
        self.message = message
    }
}

private func testConductorDatabase() throws -> any DatabaseWriter {
    let database = try DatabaseQueue()
    try database.write { db in
        try db.execute(
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
    return database
}
