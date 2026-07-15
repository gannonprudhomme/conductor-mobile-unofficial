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

        let databaseURL = rootURL.appending(path: "conductor.db")
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
        let application = Server.makeApplication(
            database: database,
            port: 0,
            allowedOrigin: "ws://localhost"
        )

        try await application.test(.live) { client in
            try await client.execute(uri: "/ping", method: .get) { response in
                #expect(response.status == .noContent)
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
                #expect(changed.map(\.id) == ["message-1", "message-2"])
            }

            try await client.execute(
                uri: "/repositories/repository-1/icon",
                method: .get
            ) { response in
                #expect(response.status == .ok)
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
                "/workspaces/workspace-1/sessions/session-1/messages",
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
