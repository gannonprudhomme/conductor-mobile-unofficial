//
//  WorkspaceRouteTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/13/26.
//

import Foundation
import Hummingbird
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
            model: .init(rawValue: "gpt-5"),
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
            model: .init(rawValue: "gpt-5"),
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
            model: .init(rawValue: "gpt-5"),
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
            model: .init(rawValue: "gpt-5"),
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

    @Test("Creating a workspace opens a strictly percent-encoded Conductor deep link")
    func createWorkspace() async throws {
        let database = try testConductorDatabase()
        try await insertRepository(
            id: "repository-1",
            rootPath: "/Users/example/Projects/Conductor Mobile",
            into: database
        )
        let openedURL = OpenedURL()
        let application = Server.makeApplication(
            database: database,
            openURL: { await openedURL.set($0) }
        )

        try await application.test(.router) { client in
            let body = ByteBuffer(
                string: #"{"repository_id":"repository-1","prompt":"Fix sheets & menus"}"#
            )
            try await client.execute(uri: "/workspaces", method: .post, body: body) { response in
                #expect(response.status == .accepted)
            }
        }

        let url = await openedURL.value
        #expect(
            url?.absoluteString
                == "conductor://prompt=Fix%20sheets%20%26%20menus&path=%2FUsers%2Fexample%2FProjects%2FConductor%20Mobile"
        )
    }

    @Test("Creating a workspace rejects unusable repositories")
    func createWorkspaceWithUnusableRepository() async throws {
        let database = try testConductorDatabase()
        try await insertRepository(id: "missing-path", rootPath: nil, into: database)
        try await insertRepository(id: "blank-path", rootPath: "  ", into: database)
        let openedURL = OpenedURL()
        let application = Server.makeApplication(
            database: database,
            openURL: { await openedURL.set($0) }
        )

        try await application.test(.router) { client in
            let cases: [(repositoryID: String, status: HTTPResponse.Status)] = [
                ("  ", .badRequest),
                ("missing", .notFound),
                ("missing-path", .notFound),
                ("blank-path", .notFound),
            ]
            for item in cases {
                let body = ByteBuffer(
                    string: #"{"repository_id":"\#(item.repositoryID)","prompt":""}"#
                )
                try await client.execute(
                    uri: "/workspaces",
                    method: .post,
                    body: body
                ) { response in
                    #expect(response.status == item.status)
                }
            }
        }

        #expect(await openedURL.value == nil)
    }

    @Test("Creating a workspace reports URL opening failures")
    func createWorkspaceOpenFailure() async throws {
        let database = try testConductorDatabase()
        try await insertRepository(
            id: "repository-1",
            rootPath: "/Users/example/Projects/Conductor Mobile",
            into: database
        )
        let application = Server.makeApplication(
            database: database,
            openURL: { _ in throw OpenError() }
        )

        try await application.test(.router) { client in
            let body = ByteBuffer(string: #"{"repository_id":"repository-1","prompt":""}"#)
            try await client.execute(uri: "/workspaces", method: .post, body: body) { response in
                #expect(response.status == .internalServerError)
                #expect(String(buffer: response.body).contains("Could not open Conductor"))
            }
        }
    }
}

private actor OpenedURL {
    private(set) var value: URL?

    func set(_ value: URL) {
        self.value = value
    }
}

private struct OpenError: LocalizedError {
    var errorDescription: String? {
        "The URL could not be opened."
    }
}

private func insertRepository(
    id: String,
    rootPath: String?,
    into database: any DatabaseWriter
) async throws {
    let date = Date(timeIntervalSince1970: 1_783_555_200)
    try await database.write { database in
        try Repository
            .insert {
                Repository(
                    id: id,
                    createdAt: date,
                    rootPath: rootPath,
                    updatedAt: date
                )
            }
            .execute(database)
    }
}
