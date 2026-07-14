//
//  SessionAgentOptionsRouteTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/13/26.
//

import HummingbirdTesting
import NIOCore
import SharedConductorData
import SQLiteData
import Testing

@testable import ConductorMobileServer

struct SessionAgentOptionsRouteTests {
    @Test("POST agent options updates fast mode")
    func post() async throws {
        let database = try sessionAgentOptionsDatabase()
        let application = Server.makeApplication(database: database)

        try await application.test(.router) { client in
            try await client.execute(
                uri: "/workspaces/workspace-1/sessions/session-1/agent-options",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"fast_mode":true}"#)
            ) { response in
                #expect(response.status == .noContent)
            }
        }

        let fastMode = try await database.read { database in
            try Session.find("session-1").select(\.fastMode).fetchOne(database)
        }
        #expect(fastMode == true)
    }
}

private func sessionAgentOptionsDatabase() throws -> DatabaseQueue {
    let database = try testConductorDatabase()
    try database.write { database in
        try Session
            .insert {
                Session(
                    id: "session-1",
                    workspaceID: "workspace-1",
                    title: "Fast mode",
                    agentType: .codex,
                    isHidden: false,
                    createdAt: "2026-07-13 00:00:00",
                    updatedAt: "2026-07-13 00:00:00",
                    lastUserMessageAt: nil,
                    status: .idle,
                    model: "gpt-5.5",
                    unreadCount: 0,
                    freshlyCompacted: 0,
                    contextTokenCount: 0,
                    fastMode: false
                )
            }
            .execute(database)
    }
    return database
}
