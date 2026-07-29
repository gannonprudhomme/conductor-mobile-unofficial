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

                let resumeCursor = LockIsolated<Message.ID?>(nil)
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
                    #expect(initial.cursor == "message-1")
                    #expect(initial.queuedMessages == [])

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
                    #expect(changed.cursor == "message-2")
                    #expect(changed.queuedMessages == nil)

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
                    #expect(updated.cursor == "message-2")
                    #expect(updated.queuedMessages == nil)

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
                    #expect(deleted.cursor == "message-1")
                    #expect(deleted.queuedMessages == nil)
                    resumeCursor.withValue {
                        $0 = deleted.cursor
                    }
                }

                try await writer.write { database in
                    try database.execute(
                        sql: """
                            INSERT INTO session_messages (
                              id, session_id, role, content, created_at, sent_at
                            ) VALUES (
                              'message-3', 'session-1', 'assistant', 'Resumed.',
                              '2026-07-09T00:00:08Z', '2026-07-09T00:00:09Z'
                            )
                            """
                    )
                }
                let cursor = try #require(resumeCursor.value)
                try await client.ws(
                    "/workspaces/workspace-iso/sessions/session-1/messages"
                        + "?after=\(cursor)"
                ) { inbound, _, _ in
                    var iterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                    let suffix = try decode(
                        MessageSyncEvent.self,
                        from: try #require(await iterator.next())
                    )
                    #expect(!suffix.isSnapshot)
                    #expect(suffix.messages.map(\.id) == ["message-3"])
                    #expect(suffix.deletedMessageIDs.isEmpty)
                    #expect(suffix.cursor == "message-3")
                    #expect(suffix.queuedMessages == [])
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

    @Test("Message streams resume by history ID and fully reconcile live queues")
    func messageResumeAndQueueReconciliation() async throws {
        let writer = try testConductorDatabase()
        let composedID = "message-\u{e9}"
        let decomposedID = "message-e\u{301}"
        try await writer.write { database in
            try database.execute(
                sql: """
                    INSERT INTO workspaces (id, created_at, updated_at)
                    VALUES ('workspace', '2026-07-29T00:00:00Z', '2026-07-29T00:00:00Z');

                    INSERT INTO sessions (
                      id, workspace_id, agent_type, created_at, updated_at, status, model
                    ) VALUES (
                      'session', 'workspace', 'codex',
                      '2026-07-29T00:00:00Z', '2026-07-29T00:00:00Z', 'idle', 'gpt-5'
                    );

                    INSERT INTO session_messages (
                      id, session_id, role, content, created_at, sent_at, queue_order
                    ) VALUES
                      (
                        ?, 'session', 'assistant', 'Composed',
                        '2026-07-29T00:00:02Z', '2026-07-29T00:00:03Z', NULL
                      ),
                      (
                        ?, 'session', 'assistant', 'Decomposed',
                        '2026-07-29T00:00:02Z', '2026-07-29T00:00:03Z', NULL
                      ),
                      (
                        'first', 'session', 'user', 'First',
                        '2026-07-29T00:00:01Z', '2026-07-29T00:00:01Z', NULL
                      ),
                      (
                        'queued', 'session', 'user', 'Queued',
                        '2026-07-29T00:00:03Z', NULL, 0
                      );
                    """,
                arguments: [composedID, decomposedID]
            )
        }
        let application = Server.makeApplication(
            database: writer,
            port: 0,
            allowedOrigin: "ws://localhost"
        )

        try await application.test(.live) { client in
            let path = "/workspaces/workspace/sessions/session/messages"
            try await client.ws(path) { inbound, _, _ in
                var iterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                let initial = try decode(
                    MessageSyncEvent.self,
                    from: try #require(await iterator.next())
                )
                #expect(initial.isSnapshot)
                #expect(initial.messages.map(\.id) == ["first", decomposedID, composedID])
                #expect(initial.cursor == composedID)
                #expect(initial.queuedMessages?.map(\.id) == ["queued"])

                try await writer.write { database in
                    try database.execute(
                        sql: """
                            UPDATE session_messages
                            SET content = 'Edited queue', queue_order = 2
                            WHERE id = 'queued'
                            """
                    )
                }
                let editedQueue = try decode(
                    MessageSyncEvent.self,
                    from: try #require(await iterator.next())
                )
                #expect(!editedQueue.isSnapshot)
                #expect(editedQueue.messages.isEmpty)
                #expect(editedQueue.deletedMessageIDs.isEmpty)
                #expect(editedQueue.queuedMessages?.map(\.content) == ["Edited queue"])

                try await writer.write { database in
                    try database.execute(
                        sql: """
                            INSERT INTO session_messages (
                              id, session_id, role, content, created_at, queue_order
                            ) VALUES (
                              'queued-2', 'session', 'user', 'Second queued',
                              '2026-07-29T00:00:03Z', 0
                            )
                            """
                    )
                }
                let addedQueue = try decode(
                    MessageSyncEvent.self,
                    from: try #require(await iterator.next())
                )
                #expect(addedQueue.queuedMessages?.map(\.id) == ["queued-2", "queued"])

                try await writer.write { database in
                    try database.execute(
                        sql: """
                            UPDATE session_messages
                            SET queue_order = CASE id
                              WHEN 'queued' THEN 0
                              WHEN 'queued-2' THEN 1
                            END
                            WHERE id IN ('queued', 'queued-2')
                            """
                    )
                }
                let reorderedQueue = try decode(
                    MessageSyncEvent.self,
                    from: try #require(await iterator.next())
                )
                #expect(reorderedQueue.queuedMessages?.map(\.id) == ["queued", "queued-2"])

                try await writer.write { database in
                    try database.execute(
                        sql: "DELETE FROM session_messages WHERE id = 'queued-2'"
                    )
                }
                let deletedQueue = try decode(
                    MessageSyncEvent.self,
                    from: try #require(await iterator.next())
                )
                #expect(deletedQueue.deletedMessageIDs.isEmpty)
                #expect(deletedQueue.queuedMessages?.map(\.id) == ["queued"])

                try await writer.write { database in
                    try database.execute(
                        sql: """
                            UPDATE session_messages
                            SET sent_at = '2026-07-29T00:00:04Z', queue_order = NULL
                            WHERE id = 'queued'
                            """
                    )
                }
                let completedQueue = try decode(
                    MessageSyncEvent.self,
                    from: try #require(await iterator.next())
                )
                #expect(completedQueue.messages.map(\.id) == ["queued"])
                #expect(completedQueue.queuedMessages == [])
                #expect(completedQueue.cursor == "queued")

                let composedQueueID = "queue-\u{e9}"
                let decomposedQueueID = "queue-e\u{301}"
                try await writer.write { database in
                    try database.execute(
                        sql: """
                            INSERT INTO session_messages (
                              id, session_id, role, content, created_at, queue_order
                            ) VALUES (
                              ?, 'session', 'user', 'Raw queue identity',
                              '2026-07-29T00:00:05Z', 0
                            )
                            """,
                        arguments: [composedQueueID]
                    )
                }
                _ = try decode(
                    MessageSyncEvent.self,
                    from: try #require(await iterator.next())
                )
                try await writer.write { database in
                    try database.execute(
                        sql: """
                            UPDATE session_messages
                            SET id = ?
                            WHERE id = ?
                            """,
                        arguments: [decomposedQueueID, composedQueueID]
                    )
                }
                let rawQueueIDChange = try decode(
                    MessageSyncEvent.self,
                    from: try #require(await iterator.next())
                )
                #expect(rawQueueIDChange.queuedMessages?.map(\.id) == [decomposedQueueID])
                try await writer.write { database in
                    try database.execute(
                        sql: "DELETE FROM session_messages WHERE id = ?",
                        arguments: [decomposedQueueID]
                    )
                }
                _ = try decode(
                    MessageSyncEvent.self,
                    from: try #require(await iterator.next())
                )

                try await writer.write { database in
                    try database.execute(
                        sql: "UPDATE session_messages SET content = 'Updated' WHERE id = 'first'"
                    )
                }
                let updatedHistory = try decode(
                    MessageSyncEvent.self,
                    from: try #require(await iterator.next())
                )
                #expect(updatedHistory.messages.map(\.id) == ["first"])
                #expect(updatedHistory.deletedMessageIDs.isEmpty)
                #expect(updatedHistory.queuedMessages == nil)

                try await writer.write { database in
                    try database.execute(
                        sql: "DELETE FROM session_messages WHERE id = 'first'"
                    )
                }
                let deletedHistory = try decode(
                    MessageSyncEvent.self,
                    from: try #require(await iterator.next())
                )
                #expect(deletedHistory.messages.isEmpty)
                #expect(deletedHistory.deletedMessageIDs == ["first"])
                #expect(deletedHistory.queuedMessages == nil)
            }

            try await writer.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO session_messages (
                          id, session_id, role, content, created_at, queue_order
                        ) VALUES (
                          'queued-current', 'session', 'user', 'Still queued',
                          '2026-07-29T00:00:05Z', 0
                        )
                        """
                )
            }

            try await client.ws(path + "?after=message-e%CC%81") { inbound, _, _ in
                var iterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                let suffix = try decode(
                    MessageSyncEvent.self,
                    from: try #require(await iterator.next())
                )
                #expect(!suffix.isSnapshot)
                #expect(suffix.messages.map(\.id) == [composedID, "queued"])
                #expect(suffix.queuedMessages?.map(\.id) == ["queued-current"])
            }

            for invalidCursor in [
                "missing",
                "queued-current",
            ] {
                try await client.ws(path + "?after=\(invalidCursor)") { inbound, _, _ in
                    var iterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                    let snapshot = try decode(
                        MessageSyncEvent.self,
                        from: try #require(await iterator.next())
                    )
                    #expect(snapshot.isSnapshot)
                    #expect(snapshot.queuedMessages?.map(\.id) == ["queued-current"])
                }
            }

            try await client.ws(path + "?after=queued") { inbound, _, _ in
                var iterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                let noNewHistory = try decode(
                    MessageSyncEvent.self,
                    from: try #require(await iterator.next())
                )
                #expect(!noNewHistory.isSnapshot)
                #expect(noNewHistory.messages.isEmpty)
                #expect(noNewHistory.cursor == "queued")
                #expect(noNewHistory.queuedMessages?.map(\.id) == ["queued-current"])
            }

            try await client.ws(path + "?after=queued&after=first") { inbound, _, _ in
                var iterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                let duplicateCursor = try decode(
                    MessageSyncEvent.self,
                    from: try #require(await iterator.next())
                )
                #expect(duplicateCursor.isSnapshot)
            }

            try await client.ws(path + "?after=%") { inbound, _, _ in
                var iterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                let malformedCursor = try decode(
                    MessageSyncEvent.self,
                    from: try #require(await iterator.next())
                )
                #expect(malformedCursor.isSnapshot)
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
