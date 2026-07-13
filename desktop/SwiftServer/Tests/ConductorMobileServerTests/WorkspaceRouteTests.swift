//
//  WorkspaceRouteTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/13/26.
//

import Foundation
import HummingbirdTesting
import NIOCore
import SharedConductorData
import SQLiteData
import Testing

@testable import ConductorMobileServer

struct WorkspaceRouteTests {
    @Test("Workspace mutation routes update Conductor state")
    func workspaceMutations() async throws {
        let database = try testConductorDatabase()
        let date = Date(timeIntervalSince1970: 1_783_555_200)
        let workspace = Workspace(
            id: "workspace",
            activeSessionID: "active",
            createdAt: date,
            updatedAt: date
        )
        let emptyWorkspace = Workspace(
            id: "empty",
            createdAt: date,
            updatedAt: date
        )
        let fallbackSession = Session(
            id: "fallback",
            workspaceID: emptyWorkspace.id,
            title: "Fallback",
            agentType: .codex,
            isHidden: false,
            createdAt: "2026-07-09T00:00:00Z",
            updatedAt: "2026-07-09T00:00:04Z",
            lastUserMessageAt: nil,
            status: .idle,
            model: "gpt-5",
            unreadCount: 0,
            freshlyCompacted: 0,
            contextTokenCount: 0
        )
        let olderSession = Session(
            id: "older",
            workspaceID: workspace.id,
            title: "Older",
            agentType: .codex,
            isHidden: false,
            createdAt: "2026-07-09T00:00:00Z",
            updatedAt: "2026-07-09T00:00:01Z",
            lastUserMessageAt: nil,
            status: .idle,
            model: "gpt-5",
            unreadCount: 3,
            freshlyCompacted: 0,
            contextTokenCount: 0
        )
        let activeSession = Session(
            id: "active",
            workspaceID: workspace.id,
            title: "Active",
            agentType: .codex,
            isHidden: false,
            createdAt: "2026-07-09T00:00:00Z",
            updatedAt: "2026-07-09T00:00:02Z",
            lastUserMessageAt: nil,
            status: .idle,
            model: "gpt-5",
            unreadCount: 0,
            freshlyCompacted: 0,
            contextTokenCount: 0
        )
        let hiddenSession = Session(
            id: "hidden",
            workspaceID: workspace.id,
            title: "Hidden",
            agentType: .codex,
            isHidden: true,
            createdAt: "2026-07-09T00:00:00Z",
            updatedAt: "2026-07-09T00:00:03Z",
            lastUserMessageAt: nil,
            status: .idle,
            model: "gpt-5",
            unreadCount: 7,
            freshlyCompacted: 0,
            contextTokenCount: 0
        )
        try await database.write { database in
            try Workspace
                .insert { [workspace, emptyWorkspace] }
                .execute(database)
            try Session
                .insert { [olderSession, activeSession, hiddenSession, fallbackSession] }
                .execute(database)
            try database.execute(
                sql: """
                    CREATE TRIGGER update_session_recency
                    AFTER UPDATE OF unread_count ON sessions
                    BEGIN
                      UPDATE sessions SET updated_at = 'triggered' WHERE id = NEW.id;
                    END;
                    """
            )
        }
        let application = Server.makeApplication(database: database)

        try await application.test(.router) { client in
            try await client.execute(
                uri: "/workspaces/workspace",
                method: .patch,
                body: ByteBuffer(string: #"{"unread":false}"#)
            ) { response in
                #expect(response.status == .noContent)
            }

            let readState = try await database.read { database in
                (
                    active: try Session
                        .find(activeSession.id)
                        .fetchOne(database),
                    older: try Session
                        .find(olderSession.id)
                        .fetchOne(database),
                    hidden: try Session
                        .find(hiddenSession.id)
                        .fetchOne(database)
                )
            }
            #expect(readState.active?.updatedAt == activeSession.updatedAt)
            #expect(readState.older?.updatedAt == "triggered")
            #expect(readState.hidden?.updatedAt == hiddenSession.updatedAt)

            try await client.execute(
                uri: "/workspaces/workspace",
                method: .patch,
                body: ByteBuffer(
                    string: #"{"pinned":true,"status":"in-review","unread":true}"#
                )
            ) { response in
                #expect(response.status == .noContent)
            }

            let pinnedAt = try await database.read { database in
                let workspace = try Workspace
                    .find(workspace.id)
                    .fetchOne(database)
                return workspace?.pinnedAt
            }
            #expect(pinnedAt != nil)

            try await client.execute(
                uri: "/workspaces/workspace",
                method: .patch,
                body: ByteBuffer(string: #"{"pinned":false}"#)
            ) { response in
                #expect(response.status == .noContent)
            }
            try await client.execute(
                uri: "/workspaces/workspace",
                method: .patch,
                body: ByteBuffer(string: #"{"pinned":true,"status":"unknown"}"#)
            ) { response in
                #expect(response.status == .badRequest)
            }
            try await client.execute(
                uri: "/workspaces/missing",
                method: .patch,
                body: ByteBuffer(string: #"{"pinned":true}"#)
            ) { response in
                #expect(response.status == .notFound)
            }
            try await client.execute(
                uri: "/workspaces/empty",
                method: .patch,
                body: ByteBuffer(string: #"{"unread":true}"#)
            ) { response in
                #expect(response.status == .conflict)
            }
            try await client.execute(
                uri: "/workspaces/workspace",
                method: .patch,
                body: ByteBuffer(string: "{}")
            ) { response in
                #expect(response.status == .badRequest)
            }
        }

        let state = try await database.read { database in
            (
                active: try Session
                    .find(activeSession.id)
                    .fetchOne(database),
                fallback: try Session
                    .find(fallbackSession.id)
                    .fetchOne(database),
                older: try Session
                    .find(olderSession.id)
                    .fetchOne(database),
                hidden: try Session
                    .find(hiddenSession.id)
                    .fetchOne(database),
                workspace: try Workspace
                    .find(workspace.id)
                    .fetchOne(database)
            )
        }
        #expect(state.active?.unreadCount == 1)
        #expect(state.fallback?.unreadCount == 0)
        #expect(state.older?.unreadCount == 0)
        #expect(state.hidden?.unreadCount == 7)
        #expect(state.workspace?.pinnedAt == nil)
        #expect(state.workspace?.manualStatus == "in-review")
    }
}
