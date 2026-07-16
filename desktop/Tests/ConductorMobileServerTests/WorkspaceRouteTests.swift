//
//  WorkspaceRouteTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/13/26.
//

import Dependencies
import Foundation
import HummingbirdTesting
import NIOCore
import SharedConductorData
import SQLiteData
import Testing

@testable import ConductorMobileServer

struct WorkspaceRouteTests {
    @Test("Live mutations return only after Conductor persists them")
    func liveMutations() async throws {
        let (database, workspace, activeSession, _, _) = try await workspaceRouteDatabase()
        let uiHook = WorkspaceUIHook.liveValue
        let connection = await uiHook.connect()
        let browser = Task {
            var events = connection.events.makeAsyncIterator()

            _ = try #require(await events.next())
            let pinnedAt: String? = "2026-07-15T00:00:00Z"
            try await database.write { database in
                try Workspace
                    .find(workspace.id)
                    .update { $0.pinnedAt = #bind(pinnedAt) }
                    .execute(database)
            }

            _ = try #require(await events.next())
            let status = Workspace.Status.inReview.rawValue
            try await database.write { database in
                try Workspace
                    .find(workspace.id)
                    .update { $0.manualStatus = #bind(status) }
                    .execute(database)
            }

            _ = try #require(await events.next())
            try await database.write { database in
                try Session
                    .find(activeSession.id)
                    .update { $0.unreadCount = 1 }
                    .execute(database)
            }
        }
        try await withDependencies {
            $0.workspaceUIHook = uiHook
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                for body in [
                    #"{"pinned":true}"#,
                    #"{"status":"in-review"}"#,
                    #"{"unread":true}"#,
                ] {
                    try await client.execute(
                        uri: "/workspaces/\(workspace.id)",
                        method: .patch,
                        body: ByteBuffer(string: body)
                    ) { response in
                        #expect(response.status == .noContent)
                        #expect(response.body.readableBytes == 0)
                    }
                }
            }
        }
        try await browser.value

        let state = try await database.read { database in
            (
                session: try Session.find(activeSession.id).fetchOne(database),
                workspace: try Workspace.find(workspace.id).fetchOne(database)
            )
        }
        #expect(state.session?.unreadCount == 1)
        #expect(state.workspace?.pinnedAt == "2026-07-15T00:00:00Z")
        #expect(state.workspace?.manualStatus == Workspace.Status.inReview.rawValue)
    }

    @Test("A definite disconnection commits each mutation through SQLite")
    func fallbackMutations() async throws {
        let (database, workspace, activeSession, olderSession, hiddenSession) =
            try await workspaceRouteDatabase()
        try await withDependencies {
            $0.workspaceUIHook = .liveValue
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                for body in [
                    #"{"unread":false}"#,
                    #"{"pinned":true}"#,
                    #"{"status":"in-review"}"#,
                    #"{"unread":true}"#,
                ] {
                    try await client.execute(
                        uri: "/workspaces/\(workspace.id)",
                        method: .patch,
                        body: ByteBuffer(string: body)
                    ) { response in
                        #expect(response.status == .accepted)
                        #expect(response.body.readableBytes == 0)
                    }
                }
            }
        }

        let state = try await database.read { database in
            (
                active: try Session.find(activeSession.id).fetchOne(database),
                hidden: try Session.find(hiddenSession.id).fetchOne(database),
                older: try Session.find(olderSession.id).fetchOne(database),
                workspace: try Workspace.find(workspace.id).fetchOne(database)
            )
        }
        #expect(state.active?.unreadCount == 1)
        #expect(state.older?.unreadCount == 0)
        #expect(state.hidden?.unreadCount == hiddenSession.unreadCount)
        #expect(state.workspace?.pinnedAt != nil)
        #expect(state.workspace?.manualStatus == Workspace.Status.inReview.rawValue)
    }

    @Test("Workspace PATCH accepts exactly one valid absolute field")
    func invalidBodies() async throws {
        let (database, workspace, _, _, _) = try await workspaceRouteDatabase()
        let application = Server.makeApplication(database: database)

        try await application.test(.router) { client in
            for body in [
                "{}",
                #"{"pinned":true,"status":"done"}"#,
                #"{"pinned":true,"extra":false}"#,
                #"{"extra":true}"#,
                #"{"pinned":"true"}"#,
                #"{"status":"unknown"}"#,
            ] {
                try await client.execute(
                    uri: "/workspaces/\(workspace.id)",
                    method: .patch,
                    body: ByteBuffer(string: body)
                ) { response in
                    #expect(response.status == .badRequest)
                }
            }

            try await client.execute(
                uri: "/workspaces/missing",
                method: .patch,
                body: ByteBuffer(string: #"{"pinned":true}"#)
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test("Fallback reports conflict when unread has no active visible session")
    func fallbackConflict() async throws {
        let database = try testConductorDatabase()
        let date = Date(timeIntervalSince1970: 1_783_555_200)
        let workspace = Workspace(id: "workspace", createdAt: date, updatedAt: date)
        try await database.write { database in
            try Workspace.insert { workspace }.execute(database)
        }
        try await withDependencies {
            $0.workspaceUIHook = .liveValue
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/\(workspace.id)",
                    method: .patch,
                    body: ByteBuffer(string: #"{"unread":true}"#)
                ) { response in
                    #expect(response.status == .conflict)
                }
            }
        }
    }

    @Test("An enqueued command times out without falling back")
    func liveTimeout() async throws {
        let (database, workspace, _, _, _) = try await workspaceRouteDatabase()
        let uiHook = WorkspaceUIHook.liveValue
        let connection = await uiHook.connect()
        let browser = Task {
            var events = connection.events.makeAsyncIterator()
            _ = try #require(await events.next())
            await uiHook.disconnect(connectionID: connection.id)
        }
        try await withDependencies {
            $0.workspaceUIHook = uiHook
        } operation: {
            let application = Server.makeApplication(
                database: database,
                workspaceMutationTimeout: .milliseconds(20)
            )
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/\(workspace.id)",
                    method: .patch,
                    body: ByteBuffer(string: #"{"pinned":true}"#)
                ) { response in
                    #expect(response.status == .gatewayTimeout)
                }
            }
        }
        try await browser.value

        let persistedWorkspace = try await database.read { database in
            try Workspace.find(workspace.id).fetchOne(database)
        }
        #expect(persistedWorkspace?.pinnedAt == nil)
    }
}

private func workspaceRouteDatabase() async throws -> (
    DatabaseQueue,
    Workspace,
    Session,
    Session,
    Session
) {
    let database = try testConductorDatabase()
    let date = Date(timeIntervalSince1970: 1_783_555_200)
    let workspace = Workspace(
        id: "workspace",
        activeSessionID: "active",
        createdAt: date,
        updatedAt: date
    )
    func session(
        _ id: String,
        isHidden: Bool = false,
        unreadCount: Int = 0
    ) -> Session {
        Session(
            id: id,
            workspaceID: workspace.id,
            title: id.capitalized,
            agentType: .codex,
            isHidden: isHidden,
            createdAt: "2026-07-09T00:00:00Z",
            updatedAt: "2026-07-09T00:00:00Z",
            lastUserMessageAt: nil,
            status: .idle,
            model: .init(rawValue: "gpt-5"),
            unreadCount: unreadCount,
            freshlyCompacted: 0,
            contextTokenCount: 0
        )
    }
    let olderSession = session("older", unreadCount: 3)
    let activeSession = session("active")
    let hiddenSession = session("hidden", isHidden: true, unreadCount: 7)
    try await database.write { database in
        try Workspace.insert { workspace }.execute(database)
        try Session
            .insert { [olderSession, activeSession, hiddenSession] }
            .execute(database)
    }
    return (database, workspace, activeSession, olderSession, hiddenSession)
}
