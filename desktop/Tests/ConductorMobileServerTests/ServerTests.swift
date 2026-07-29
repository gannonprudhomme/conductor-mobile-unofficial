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
                      'session-1', 'workspace-iso', NULL, 'codex',
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
                    let settings = try #require(
                        JSONSerialization.jsonObject(
                            with: Data(response.body.readableBytesView)
                        ) as? [String: Any]
                    )
                    #expect(settings["defaultModel"] as? String == "gpt-5.6-sol")
                    #expect(settings["defaultFastMode"] as? Bool == false)
                    #expect(settings["defaultReasoningEffort"] as? String == "high")
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
                    #expect(initial.first?.title == nil)

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
                        MessageSyncEvent.self,
                        from: try #require(await iterator.next())
                    )
                    #expect(initial.isSnapshot)
                    #expect(initial.messages.map(\.id) == ["message-1"])
                    #expect(initial.deletedMessageIDs.isEmpty)

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
                        MessageSyncEvent.self,
                        from: try #require(await iterator.next())
                    )
                    #expect(!changed.isSnapshot)
                    #expect(changed.messages.map(\.id) == ["message-2"])
                    #expect(changed.deletedMessageIDs.isEmpty)

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
                        MessageSyncEvent.self,
                        from: try #require(await iterator.next())
                    )
                    #expect(!updated.isSnapshot)
                    #expect(updated.messages.map(\.id) == ["message-1"])
                    #expect(updated.messages.first?.content == "Updated.")
                    #expect(updated.deletedMessageIDs.isEmpty)

                    try await writer.write { database in
                        try database.execute(
                            sql: "DELETE FROM session_messages WHERE id = 'message-2'"
                        )
                    }
                    let deleted = try decode(
                        MessageSyncEvent.self,
                        from: try #require(await iterator.next())
                    )
                    #expect(!deleted.isSnapshot)
                    #expect(deleted.messages.isEmpty)
                    #expect(deleted.deletedMessageIDs == ["message-2"])
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

    @Test("Multiple message clients remain connected through unrelated database changes")
    func multipleWebSocketClients() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString)-conductor.db")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let writer = try DatabaseQueue(
            path: databaseURL.path,
            configuration: configuration
        )
        try await writer.write { database in
            try createTestConductorSchema(in: database)
        }
        let date = Date(timeIntervalSince1970: 1_783_555_200)
        let workspace = Workspace(
            id: "workspace",
            createdAt: date,
            updatedAt: date,
            workspaceName: "revision-0"
        )
        let session = Session(
            id: "session",
            workspaceID: workspace.id,
            title: "Large transcript",
            agentType: .codex,
            isHidden: false,
            createdAt: "2026-07-29T00:00:00Z",
            updatedAt: "2026-07-29T00:00:00Z",
            lastUserMessageAt: nil,
            status: .idle,
            model: .gpt_5_6_sol,
            unreadCount: 0,
            freshlyCompacted: 0,
            contextTokenCount: 0
        )
        let content = String(repeating: "x", count: 8_192)
        let messages = (0..<2_000).map { index in
            Message(
                id: "message-\(index)",
                sessionID: session.id,
                role: .assistant,
                content: content,
                createdAt: date.addingTimeInterval(TimeInterval(index)),
                sentAt: date.addingTimeInterval(TimeInterval(index))
            )
        }
        try await writer.write { database in
            try Workspace.insert { workspace }.execute(database)
            try Session.insert { session }.execute(database)
            try Message.insert { messages }.execute(database)
        }

        let database = try ConductorDatabase.open(at: databaseURL)
        let writerJournalMode = try await writer.read { database in
            try #sql("PRAGMA journal_mode", as: String.self).fetchOne(database)
        }
        let readerJournalMode = try await database.read { database in
            try #sql("PRAGMA journal_mode", as: String.self).fetchOne(database)
        }
        #expect(writerJournalMode == "wal")
        #expect(readerJournalMode == "wal")
        let application = Server.makeApplication(
            database: database,
            port: 0,
            allowedOrigin: "ws://localhost"
        )
        let connectedClientIDs = LockIsolated<Set<Int>>([])
        let clientCount = 12
        let unrelatedRevisionCount = 20

        try await application.test(.live) { client in
            try await withThrowingTaskGroup(of: Void.self) { group in
                for clientID in 0..<clientCount {
                    group.addTask {
                        try await client.ws(
                            "/workspaces/\(workspace.id)/sessions/\(session.id)/messages"
                        ) { inbound, _, _ in
                            var iterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                            let initial = try decode(
                                MessageSyncEvent.self,
                                from: try #require(await iterator.next())
                            )
                            #expect(initial.messages.count == messages.count)
                            connectedClientIDs.withValue {
                                _ = $0.insert(clientID)
                            }

                            while let message = try await iterator.next() {
                                let event = try decode(
                                    MessageSyncEvent.self,
                                    from: message
                                )
                                if event.messages.first?.content == "final revision" {
                                    return
                                }
                            }

                            Issue.record("Client \(clientID) disconnected before the final revision.")
                        }
                    }
                }

                let clock = ContinuousClock()
                let connectionDeadline = clock.now.advanced(by: .seconds(10))
                while connectedClientIDs.value.count < clientCount,
                      clock.now < connectionDeadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(connectedClientIDs.value.count == clientCount)

                for revision in 1...unrelatedRevisionCount {
                    let workspaceName = "revision-\(revision)"
                    try await writer.write { database in
                        try Workspace
                            .find(workspace.id)
                            .update { $0.workspaceName = #bind(workspaceName) }
                            .execute(database)
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }

                let finalMessageID = try #require(messages.last?.id)
                try await writer.write { database in
                    try Message
                        .find(finalMessageID)
                        .update { $0.content = #bind("final revision") }
                        .execute(database)
                }

                try await group.waitForAll()
            }
        }
    }

    @Test("Managed settings override user model settings")
    func managedSettingsOverrideUserDefaultModel() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let userSettingsURL = rootURL.appending(path: "settings.toml")
        try """
            [models]
            default = "codex:gpt-5.4"
            default_fast_mode = true

            [models.codex]
            default_thinking_level = "xhigh"
            """
            .write(to: userSettingsURL, atomically: true, encoding: .utf8)

        let managedSettingsURL = rootURL.appending(path: "settings.managed.toml")
        try """
            [models]
            default = "codex:gpt-5.6-luna"

            [models.codex]
            default_thinking_level = "low"
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
                let settings = try #require(
                    JSONSerialization.jsonObject(
                        with: Data(response.body.readableBytesView)
                    ) as? [String: Any]
                )
                #expect(settings["defaultModel"] as? String == "gpt-5.6-luna")
                #expect(settings["defaultFastMode"] as? Bool == true)
                #expect(settings["defaultReasoningEffort"] as? String == "low")
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
