//
//  WorkspaceRouteTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/13/26.
//

import Dependencies
import Foundation
import Hummingbird
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
            try await database.write { database in
                try Workspace
                    .find(workspace.id)
                    .update {
                        $0.branch = #bind("renamed-branch")
                        $0.userSetBranchName = #bind(1)
                    }
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

            _ = try #require(await events.next())
            try await database.write { database in
                try Workspace
                    .find(workspace.id)
                    .update { $0.state = #bind(Workspace.State.archiving) }
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
                    #"{"branch":"renamed-branch"}"#,
                    #"{"status":"in-review"}"#,
                    #"{"unread":true}"#,
                    #"{"archive":true}"#,
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
        #expect(state.workspace?.branch == "renamed-branch")
        #expect(state.workspace?.userSetBranchName == 1)
        #expect(state.workspace?.manualStatus == Workspace.Status.inReview.rawValue)
        #expect(state.workspace?.state == .archiving)
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
                #"{"archive":false}"#,
                #"{"branch":""}"#,
                #"{"branch":"   "}"#,
                #"{"branch":true}"#,
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

    @Test("Archive requires the UI hook")
    func archiveRequiresUIHook() async throws {
        let (database, workspace, _, _, _) = try await workspaceRouteDatabase()
        let application = Server.makeApplication(database: database)

        try await withDependencies {
            $0.workspaceUIHook = .liveValue
        } operation: {
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/\(workspace.id)",
                    method: .patch,
                    body: ByteBuffer(string: #"{"archive":true}"#)
                ) { response in
                    #expect(response.status == .serviceUnavailable)
                }
            }
        }

        let persistedWorkspace = try await database.read { database in
            try Workspace.find(workspace.id).fetchOne(database)
        }
        #expect(persistedWorkspace?.state != .archived)
    }

    @Test("Branch rename requires the UI hook")
    func branchRenameRequiresUIHook() async throws {
        let (database, workspace, _, _, _) = try await workspaceRouteDatabase()
        let application = Server.makeApplication(database: database)

        try await withDependencies {
            $0.workspaceUIHook = .liveValue
        } operation: {
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/\(workspace.id)",
                    method: .patch,
                    body: ByteBuffer(string: #"{"branch":"renamed-branch"}"#)
                ) { response in
                    #expect(response.status == .serviceUnavailable)
                }
            }
        }

        let persistedWorkspace = try await database.read { database in
            try Workspace.find(workspace.id).fetchOne(database)
        }
        #expect(persistedWorkspace?.branch == workspace.branch)
        #expect(persistedWorkspace?.userSetBranchName == workspace.userSetBranchName)
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
                uiCommandTimeout: .milliseconds(20)
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

    @Test("Creating a workspace finds its initial session and persists Fast Mode")
    func createWorkspace() async throws {
        let database = try testConductorDatabase()
        try await insertRepository(id: "repository-1", into: database)
        let workspaceID = UUID(0).uuidString.lowercased()
        let session = Session(
            id: "session-1",
            workspaceID: workspaceID,
            title: "Untitled",
            agentType: .codex,
            isHidden: false,
            createdAt: "2026-07-17T00:00:00Z",
            updatedAt: "2026-07-17T00:00:00Z",
            lastUserMessageAt: nil,
            status: .idle,
            model: .gpt_5_6_terra,
            unreadCount: 0,
            freshlyCompacted: 0,
            contextTokenCount: 0,
            isFastModeEnabled: false
        )
        let workspace = Workspace(
            id: workspaceID,
            createdAt: Date(timeIntervalSince1970: 1_783_555_200),
            repositoryID: "repository-1",
            updatedAt: Date(timeIntervalSince1970: 1_783_555_200)
        )

        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            var uiHook = WorkspaceUIHook.liveValue
            uiHook.createWorkspace = {
                command,
                waitUntilChangeAvailableInDatabase in
                #expect(
                    command == CreateWorkspaceCommand(
                        repositoryID: "repository-1",
                        workspaceID: workspaceID,
                        agentType: "codex",
                        model: "gpt-5.6-terra"
                    )
                )
                try await database.write { database in
                    try Workspace.insert { workspace }.execute(database)
                    try Session.insert { session }.execute(database)
                }
                try await waitUntilChangeAvailableInDatabase()
                return true
            }
            $0.workspaceUIHook = uiHook
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                let body = ByteBuffer(
                    string: #"{"workspace_id":"00000000-0000-0000-0000-000000000000","repository_id":"repository-1","agent_type":"codex","model":"gpt-5.6-terra","fast_mode":true}"#
                )
                for _ in 0..<2 {
                    try await client.execute(
                        uri: "/workspaces",
                        method: .post,
                        body: body
                    ) { response in
                        #expect(response.status == .ok)
                        let createdWorkspace = try JSONDecoder.conductor.decode(
                            CreatedWorkspace.self,
                            from: Data(response.body.readableBytesView)
                        )
                        #expect(createdWorkspace.session.isFastModeEnabled == true)
                        #expect(createdWorkspace.workspace == workspace)
                    }
                }
            }
        }
    }

    @Test("Creating a workspace validates its repository, agent, and model")
    func invalidWorkspaceCreation() async throws {
        let database = try testConductorDatabase()
        try await insertRepository(id: "repository-1", into: database)
        let application = Server.makeApplication(database: database)
        let workspaceID = "00000000-0000-0000-0000-000000000000"

        try await application.test(.router) { client in
            let cases: [(body: String, status: HTTPResponse.Status)] = [
                (
                    #"{"workspace_id":"invalid","repository_id":"repository-1","agent_type":"codex","model":"gpt-5.6-sol","fast_mode":false}"#,
                    .badRequest
                ),
                (
                    #"{"workspace_id":"\#(workspaceID)","repository_id":"  ","agent_type":"codex","model":"gpt-5.6-sol","fast_mode":false}"#,
                    .badRequest
                ),
                (
                    #"{"workspace_id":"\#(workspaceID)","repository_id":"missing","agent_type":"codex","model":"gpt-5.6-sol","fast_mode":false}"#,
                    .notFound
                ),
                (
                    #"{"workspace_id":"\#(workspaceID)","repository_id":"repository-1","agent_type":"claude","model":"gpt-5.6-sol","fast_mode":false}"#,
                    .badRequest
                ),
                (
                    #"{"workspace_id":"\#(workspaceID)","repository_id":"repository-1","agent_type":"codex","model":"unknown","fast_mode":false}"#,
                    .badRequest
                ),
            ]
            for item in cases {
                try await client.execute(
                    uri: "/workspaces",
                    method: .post,
                    body: ByteBuffer(string: item.body)
                ) { response in
                    #expect(response.status == item.status)
                }
            }
        }
    }

    @Test("Creating a workspace requires the Conductor UI hook")
    func createWorkspaceRequiresHook() async throws {
        let database = try testConductorDatabase()
        try await insertRepository(id: "repository-1", into: database)
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0.workspaceUIHook = .liveValue
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                let body = ByteBuffer(
                    string: #"{"workspace_id":"00000000-0000-0000-0000-000000000000","repository_id":"repository-1","agent_type":"codex","model":"gpt-5.6-sol","fast_mode":false}"#
                )
                try await client.execute(uri: "/workspaces", method: .post, body: body) { response in
                    #expect(response.status == .serviceUnavailable)
                }
            }
        }
    }
}

private func insertRepository(
    id: String,
    into database: any DatabaseWriter
) async throws {
    let date = Date(timeIntervalSince1970: 1_783_555_200)
    try await database.write { database in
        try Repository
            .insert {
                Repository(
                    id: id,
                    createdAt: date,
                    updatedAt: date
                )
            }
            .execute(database)
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
        branch: "old-branch",
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
