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
