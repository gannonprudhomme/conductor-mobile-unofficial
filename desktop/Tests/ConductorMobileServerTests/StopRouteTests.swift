//
//  StopRouteTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Dependencies
import HummingbirdTesting
import NIOCore
import SQLiteData
import Synchronization
import Testing

@testable import ConductorMobileServer

struct StopRouteTests {
    @Test("POST stop forwards the selected session to the sidecar bridge")
    func post() async throws {
        let database = try stopRouteDatabase()
        let recordedRequest = Mutex<SidecarBridgeClient.RuntimeStopRequest?>(nil)

        try await withDependencies {
            $0.sidecarBridgeClient.stopSession = { request in
                recordedRequest.withLock { $0 = request }
            }
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/workspace-1/sessions/session-1/stop",
                    method: .post
                ) { response in
                    #expect(response.status == .noContent)
                    #expect(response.body.readableBytes == 0)
                }
            }
        }

        #expect(
            recordedRequest.withLock { $0 }
                == SidecarBridgeClient.RuntimeStopRequest(
                    agentType: "codex",
                    sessionID: "session-1"
                )
        )
    }

    @Test("POST stop rejects a session outside the selected workspace")
    func sessionNotFound() async throws {
        let database = try stopRouteDatabase()
        let didStop = Mutex(false)

        try await withDependencies {
            $0.sidecarBridgeClient.stopSession = { _ in
                didStop.withLock { $0 = true }
            }
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/other-workspace/sessions/session-1/stop",
                    method: .post
                ) { response in
                    #expect(response.status == .notFound)
                    #expect(String(buffer: response.body) == "Session not found.")
                }
            }
        }

        #expect(!didStop.withLock { $0 })
    }
}

private func stopRouteDatabase() throws -> DatabaseQueue {
    let database = try DatabaseQueue()
    try database.write { database in
        try database.execute(
            sql: """
                CREATE TABLE sessions (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  agent_type TEXT NOT NULL
                );

                INSERT INTO sessions (id, workspace_id, agent_type)
                VALUES ('session-1', 'workspace-1', 'codex');
                """
        )
    }
    return database
}
