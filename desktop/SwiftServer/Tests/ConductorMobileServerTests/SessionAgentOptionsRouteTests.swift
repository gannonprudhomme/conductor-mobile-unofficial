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
    @Test("POST agent options updates the selected agent's Conductor columns")
    func post() async throws {
        let database = try sessionAgentOptionsDatabase()
        let application = Server.makeApplication(database: database)

        try await application.test(.router) { client in
            try await client.execute(
                uri: "/workspaces/workspace-1/sessions/codex-session/agent-options",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(
                    string: #"{"fast_mode":true,"reasoning_effort":"ultra"}"#
                )
            ) { response in
                #expect(response.status == .noContent)
            }

            try await client.execute(
                uri: "/workspaces/workspace-1/sessions/claude-session/agent-options",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(
                    string: #"{"fast_mode":false,"reasoning_effort":"xhigh"}"#
                )
            ) { response in
                #expect(response.status == .noContent)
            }
        }

        let sessions = try await database.read { database in
            (
                try Session.find("codex-session").fetchOne(database),
                try Session.find("claude-session").fetchOne(database)
            )
        }
        let codexSession = try #require(sessions.0)
        let claudeSession = try #require(sessions.1)

        #expect(codexSession.fastMode == true)
        #expect(codexSession.codexThinkingLevel == .ultra)
        #expect(codexSession.claudeEffortLevel == nil)
        #expect(claudeSession.fastMode == false)
        #expect(claudeSession.codexThinkingLevel == nil)
        #expect(claudeSession.claudeEffortLevel == .extraHigh)
    }

    @Test("POST agent options rejects unknown reasoning effort")
    func unknownReasoningEffort() async throws {
        let database = try sessionAgentOptionsDatabase()
        let application = Server.makeApplication(database: database)

        try await application.test(.router) { client in
            try await client.execute(
                uri: "/workspaces/workspace-1/sessions/codex-session/agent-options",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(
                    string: #"{"fast_mode":true,"reasoning_effort":"future"}"#
                )
            ) { response in
                #expect(response.status == .badRequest)
                #expect(String(buffer: response.body) == "Unknown reasoning effort.")
            }
        }
    }
}

private func sessionAgentOptionsDatabase() throws -> DatabaseQueue {
    let database = try testConductorDatabase()
    let sessions = [
        Session(
            id: "codex-session",
            workspaceID: "workspace-1",
            title: "Codex",
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
        ),
        Session(
            id: "claude-session",
            workspaceID: "workspace-1",
            title: "Claude",
            agentType: .claude,
            isHidden: false,
            createdAt: "2026-07-13 00:00:00",
            updatedAt: "2026-07-13 00:00:00",
            lastUserMessageAt: nil,
            status: .idle,
            model: "sonnet",
            unreadCount: 0,
            freshlyCompacted: 0,
            contextTokenCount: 0,
            fastMode: false
        ),
    ]
    try database.write { database in
        for session in sessions {
            try Session.insert { session }.execute(database)
        }
    }
    return database
}
