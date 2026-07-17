//
//  CreateSessionRouteTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/16/26.
//

import Dependencies
import Foundation
import HummingbirdTesting
import SharedConductorData
import SQLiteData
import Testing

@testable import ConductorMobileServer

struct CreateSessionRouteTests {
    @Test("Session creation runs through Conductor and returns its canonical row")
    func createsSession() async throws {
        let (database, workspace) = try await sessionCreationDatabase()
        let uiHook = WorkspaceUIHook.liveValue
        let connection = await uiHook.connect()
        let createdSession = Session(
            id: "created",
            workspaceID: workspace.id,
            title: "Untitled",
            agentType: .codex,
            isHidden: false,
            createdAt: "2026-07-16T20:00:00Z",
            updatedAt: "2026-07-16T20:00:00Z",
            lastUserMessageAt: nil,
            status: .idle,
            model: .gpt_5_6_sol,
            unreadCount: 0,
            freshlyCompacted: 0,
            contextTokenCount: 0
        )
        let browser = Task {
            var events = connection.events.makeAsyncIterator()
            #expect(
                await events.next()
                    == "data: {\"workspaceId\":\"workspace-1\",\"createSession\":true}\n\n"
            )
            try await database.write { database in
                try Session.insert { createdSession }.execute(database)
            }
        }

        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0.workspaceUIHook = uiHook
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/\(workspace.id)/sessions",
                    method: .post
                ) { response in
                    #expect(response.status == .ok)
                    let session = try JSONDecoder.conductor.decode(
                        Session.self,
                        from: Data(response.body.readableBytesView)
                    )
                    #expect(session == createdSession)
                }
            }
        }
        try await browser.value

        let persistedWorkspace = try await database.read { database in
            try Workspace.find(workspace.id).fetchOne(database)
        }
        #expect(persistedWorkspace?.activeSessionID == "existing")
    }

    @Test("Session creation requires an existing workspace and connected UI hook")
    func requiresWorkspaceAndHook() async throws {
        let (database, workspace) = try await sessionCreationDatabase()
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0.workspaceUIHook = .liveValue
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/missing/sessions",
                    method: .post
                ) { response in
                    #expect(response.status == .notFound)
                }

                try await client.execute(
                    uri: "/workspaces/\(workspace.id)/sessions",
                    method: .post
                ) { response in
                    #expect(response.status == .serviceUnavailable)
                    #expect(String(buffer: response.body).contains("UI hook is unavailable"))
                }
            }
        }
    }

    @Test("An enqueued creation times out without writing a fallback session")
    func persistenceTimeout() async throws {
        let (database, workspace) = try await sessionCreationDatabase()
        let uiHook = WorkspaceUIHook.liveValue
        let connection = await uiHook.connect()
        let browser = Task {
            var events = connection.events.makeAsyncIterator()
            _ = await events.next()
        }

        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0.workspaceUIHook = uiHook
        } operation: {
            let application = Server.makeApplication(
                database: database,
                workspaceMutationTimeout: .milliseconds(20)
            )
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/\(workspace.id)/sessions",
                    method: .post
                ) { response in
                    #expect(response.status == .gatewayTimeout)
                }
            }
        }
        await browser.value

        let sessionCount = try await database.read { database in
            try Session
                .where { $0.workspaceID.eq(workspace.id) }
                .fetchCount(database)
        }
        #expect(sessionCount == 1)
    }
}

private func sessionCreationDatabase() async throws -> (DatabaseQueue, Workspace) {
    let database = try testConductorDatabase()
    let date = Date(timeIntervalSince1970: 1_783_555_200)
    let workspace = Workspace(
        id: "workspace-1",
        activeSessionID: "existing",
        createdAt: date,
        updatedAt: date
    )
    let session = Session(
        id: "existing",
        workspaceID: workspace.id,
        title: "Existing",
        agentType: .codex,
        isHidden: false,
        createdAt: "2026-07-16T19:00:00Z",
        updatedAt: "2026-07-16T19:00:00Z",
        lastUserMessageAt: nil,
        status: .idle,
        model: .gpt_5_6_sol,
        unreadCount: 0,
        freshlyCompacted: 0,
        contextTokenCount: 0
    )
    try await database.write { database in
        try Workspace.insert { workspace }.execute(database)
        try Session.insert { session }.execute(database)
    }
    return (database, workspace)
}
