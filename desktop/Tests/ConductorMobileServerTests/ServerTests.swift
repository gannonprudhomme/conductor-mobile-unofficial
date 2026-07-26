//
//  ServerTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Dependencies
import Foundation
import HummingbirdTesting
import HummingbirdWSClient
import HummingbirdWSTesting
import HummingbirdWebSocket
import NIOCore
import SharedConductorData
import SQLiteData
import Testing

@testable import ConductorMobileServer

struct ServerTests {
    @Test("WebSocket routes send initial and changed resource snapshots")
    func routes() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let iconData = Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        try iconData.write(to: rootURL.appending(path: "favicon.png"))

        let userSettingsURL = rootURL.appending(path: "settings.toml")
        try """
            [models]
            default = "codex:gpt-5.6-sol"
            default_fast_mode = false
            default_plan_mode = false

            [models.codex]
            default_thinking_level = "high"
            """
            .write(to: userSettingsURL, atomically: true, encoding: .utf8)

        let databaseURL = rootURL.appending(path: "conductor.db")
        let pullRequestCacheURL = rootURL
            .appending(path: "local-storage.entries/git-service-pr-v1")
        try FileManager.default.createDirectory(
            at: pullRequestCacheURL,
            withIntermediateDirectories: true
        )
        try writePullRequestCache(
            workspaceID: "workspace-iso",
            isDraft: false,
            to: pullRequestCacheURL
        )
        let writer = try testConductorDatabase(at: databaseURL)
        try await writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO workspaces (id, created_at, updated_at)
                    VALUES
                      ('workspace-sqlite', '2026-07-09 00:00:01.125', '2026-07-09 00:00:01.125'),
                      ('workspace-iso', '2026-07-09T00:00:02Z', '2026-07-09T00:00:02Z');

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
        let database = try ConductorDatabase.open(at: databaseURL)
        try await withDependencies {
            $0.workspaceUIHook = .liveValue
        } operation: {
            let application = Server.makeApplication(
                database: database,
                userSettingsURL: userSettingsURL,
                managedSettingsURL: rootURL.appending(path: "missing-managed-settings.toml"),
                port: 0,
                allowedOrigin: "ws://localhost",
                pullRequestCacheURL: pullRequestCacheURL,
                workspacePollInterval: .milliseconds(10)
            )

            try await application.test(.live) { client in
                try await client.execute(uri: "/ping", method: .get) { response in
                    #expect(response.status == .noContent)
                }

                try await client.execute(
                    uri: "/settings",
                    method: .get
                ) { response in
                    #expect(response.status == .ok)
                    let settings = try? JSONDecoder.conductor.decode(
                        [String: String].self,
                        from: Data(response.body.readableBytesView)
                    )
                    #expect(settings == ["defaultModel": "gpt-5.6-sol"])
                }

                for uri in [
                    "/sessions",
                    "/repositories",
                    "/workspaces",
                ] {
                    try await client.execute(uri: uri, method: .get) { response in
                        #expect(response.status == .notFound)
                    }
                }

                try await client.ws("/workspaces") { inbound, _, _ in
                    var iterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                    let initial = try decode(
                        WorkspaceListSnapshot.self,
                        from: try #require(await iterator.next())
                    )
                    #expect(initial.repositories.map(\.id) == ["repository-1"])
                    #expect(initial.workspaces.count == 2)
                    #expect(
                        initial.workspaces.first { $0.workspace.id == "workspace-iso" }?.isWorking
                            == true
                    )
                    #expect(
                        initial.pullRequests["workspace-iso"]?.url
                            == "https://github.com/example/repository/pull/42"
                    )

                    try await writer.write { database in
                        try database.execute(
                            sql: """
                                UPDATE workspaces
                                SET workspace_name = 'Renamed', updated_at = '2026-07-09T00:00:04Z'
                                WHERE id = 'workspace-iso'
                                """
                        )
                    }
                    let changed = try decode(
                        WorkspaceListSnapshot.self,
                        from: try #require(await iterator.next())
                    )
                    #expect(
                        changed.workspaces.first { $0.workspace.id == "workspace-iso" }?.workspace
                            .workspaceName
                            == "Renamed"
                    )

                    try writePullRequestCache(
                        workspaceID: "workspace-iso",
                        isDraft: true,
                        to: pullRequestCacheURL
                    )
                    let pullRequestChanged = try decode(
                        WorkspaceListSnapshot.self,
                        from: try #require(await iterator.next())
                    )
                    #expect(pullRequestChanged.pullRequests["workspace-iso"]?.isDraft == true)

                    try await client.execute(
                        uri: "/workspaces/workspace-iso",
                        method: .patch,
                        headers: [
                            .contentType: "application/json",
                            .origin: "ws://localhost",
                        ],
                        body: ByteBuffer(string: #"{"status":"in-review"}"#)
                    ) { response in
                        #expect(response.status == .accepted)
                    }
                    let fallback = try decode(
                        WorkspaceListSnapshot.self,
                        from: try #require(await iterator.next())
                    )
                    #expect(
                        fallback.workspaces.first { $0.workspace.id == "workspace-iso" }?.workspace
                            .manualStatus
                            == Workspace.Status.inReview.rawValue
                    )
                }

                try await client.ws("/workspaces/workspace-iso/sessions") { inbound, _, _ in
                    var iterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                    let initial = try decode(
                        [Session].self,
                        from: try #require(await iterator.next())
                    )
                    #expect(initial.map(\.id) == ["session-1"])

                    try await writer.write { database in
                        try database.execute(
                            sql: "UPDATE repos SET name = 'Unrelated' WHERE id = 'repository-1'"
                        )
                    }
                    try await Task.sleep(for: .milliseconds(150))

                    try await writer.write { database in
                        try database.execute(
                            sql: """
                                UPDATE sessions
                                SET title = 'Updated', updated_at = '2026-07-09T00:00:05Z'
                                WHERE id = 'session-1'
                                """
                        )
                    }
                    let changed = try decode(
                        [Session].self,
                        from: try #require(await iterator.next())
                    )
                    #expect(changed.first?.title == "Updated")
                }

                try await client.ws(
                    "/workspaces/workspace-iso/sessions/session-1/messages"
                ) { inbound, _, _ in
                    var iterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                    let initial = try decode(
                        [Message].self,
                        from: try #require(await iterator.next())
                    )
                    #expect(initial.map(\.id) == ["message-1"])

                    try await writer.write { database in
                        try database.execute(
                            sql: """
                                INSERT INTO session_messages (
                                  id, session_id, role, content, created_at, sent_at
                                ) VALUES (
                                  'message-2', 'session-1', 'assistant', 'Done.',
                                  '2026-07-09T00:00:06Z', '2026-07-09T00:00:07Z'
                                )
                                """
                        )
                    }
                    let changed = try decode(
                        [Message].self,
                        from: try #require(await iterator.next())
                    )
                    #expect(changed.map(\.id) == ["message-2"])

                    try await writer.write { database in
                        try database.execute(
                            sql: """
                                UPDATE session_messages
                                SET content = 'Updated.'
                                WHERE id = 'message-1'
                                """
                        )
                    }
                    let updated = try decode(
                        [Message].self,
                        from: try #require(await iterator.next())
                    )
                    #expect(updated.map(\.id) == ["message-1"])
                    #expect(updated.first?.content == "Updated.")
                }

                #if canImport(AppKit)
                try await client.execute(
                    uri: "/repositories/repository-1/icon",
                    method: .get
                ) { response in
                    #expect(response.status == .ok)
                }
                #endif
            }
        }
    }

    @Test("Managed settings override the user default model")
    func managedSettingsOverrideUserDefaultModel() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let userSettingsURL = rootURL.appending(path: "settings.toml")
        try """
            [models]
            default = "codex:gpt-5.4"
            """
            .write(to: userSettingsURL, atomically: true, encoding: .utf8)

        let managedSettingsURL = rootURL.appending(path: "settings.managed.toml")
        try """
            [models]
            default = "codex:gpt-5.6-luna"
            """
            .write(to: managedSettingsURL, atomically: true, encoding: .utf8)

        let application = Server.makeApplication(
            database: try testConductorDatabase(),
            userSettingsURL: userSettingsURL,
            managedSettingsURL: managedSettingsURL,
            port: 0
        )

        try await application.test(.live) { client in
            try await client.execute(uri: "/settings", method: .get) { response in
                #expect(response.status == .ok)
                let settings = try JSONDecoder.conductor.decode(
                    [String: String].self,
                    from: Data(response.body.readableBytesView)
                )
                #expect(settings == ["defaultModel": "gpt-5.6-luna"])
            }
        }
    }

    @Test("Browser-originated WebSocket and command requests are rejected")
    func browserOrigins() async throws {
        let database = try testConductorDatabase()
        let application = Server.makeApplication(database: database, port: 0)

        try await application.test(.live) { client in
            for uri in [
                "/workspaces",
                "/workspaces/workspace-1/sessions",
                "/workspaces/workspace-1/sessions/session-1/messages",
            ] {
                await #expect(throws: WebSocketClientError.webSocketUpgradeFailed) {
                    try await client.ws(uri) { _, _, _ in }
                }
            }

            for uri in [
                "/workspaces",
                "/workspaces/workspace-1/sessions",
                "/workspaces/workspace-1/sessions/session-1/messages",
                "/workspaces/workspace-1/sessions/session-1/messages/queue/message-1/edit",
                "/workspaces/workspace-1/sessions/session-1/messages/queue/resume",
                "/workspaces/workspace-1/sessions/session-1/stop",
            ] {
                try await client.execute(
                    uri: uri,
                    method: .post,
                    headers: [.origin: "https://malicious.example"]
                ) { response in
                    #expect(response.status == .forbidden)
                }
            }

            try await client.execute(
                uri: "/workspaces/workspace-1",
                method: .patch,
                headers: [.origin: "https://malicious.example"]
            ) { response in
                #expect(response.status == .forbidden)
            }

            try await client.execute(
                uri: "/workspaces/workspace-1/sessions/session-1/messages/queue",
                method: .patch,
                headers: [.origin: "https://malicious.example"]
            ) { response in
                #expect(response.status == .forbidden)
            }

            try await client.execute(
                uri: "/workspaces/workspace-1/sessions/session-1/messages/queue/message-1",
                method: .patch,
                headers: [.origin: "https://malicious.example"]
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }
}

private func writePullRequestCache(
    workspaceID: Workspace.ID,
    isDraft: Bool,
    to directoryURL: URL
) throws {
    try Data(
        """
        {
          "prInfo": {
            "prUrl": "https://github.com/example/repository/pull/42",
            "isDraft": \(isDraft),
            "isMerged": false,
            "mergeStateStatus": "CLEAN",
            "checksStatus": "passing"
          }
        }
        """.utf8
    )
    .write(to: directoryURL.appending(path: "\(workspaceID).json"))
}

private func decode<Value: Decodable>(
    _ type: Value.Type,
    from message: WebSocketMessage
) throws -> Value {
    let data = switch message {
    case .binary(let buffer):
        Data(buffer.readableBytesView)
    case .text(let text):
        Data(text.utf8)
    }
    return try JSONDecoder.conductor.decode(type, from: data)
}
