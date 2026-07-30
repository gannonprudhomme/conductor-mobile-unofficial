//
//  SessionRouteTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/19/26.
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

struct SessionRouteTests {
    @Test("Model history returns only the latest modeled message")
    func modelHistory() async throws {
        let (database, workspace, session) = try await sessionRouteDatabase()
        let neverUsedSession = Session(
            id: "session-2",
            workspaceID: workspace.id,
            title: "New chat",
            agentType: .codex,
            isHidden: false,
            createdAt: "2026-07-19T00:00:00Z",
            updatedAt: "2026-07-19T00:00:00Z",
            lastUserMessageAt: nil,
            status: .idle,
            model: Session.Model(rawValue: ""),
            unreadCount: 0,
            freshlyCompacted: 0,
            contextTokenCount: 0
        )
        let messages = [
            Message(
                id: "modeled-1",
                sessionID: session.id,
                createdAt: Date(timeIntervalSince1970: 1),
                model: Session.Model.gpt5_5.rawValue
            ),
            Message(
                id: "modeled-2",
                sessionID: session.id,
                createdAt: Date(timeIntervalSince1970: 2),
                model: Session.Model.gpt_5_6_sol.rawValue
            ),
            Message(
                id: "unmodeled-later",
                sessionID: session.id,
                createdAt: Date(timeIntervalSince1970: 3)
            ),
        ]
        try await database.write { database in
            try Session.insert { neverUsedSession }.execute(database)
            try Message.insert { messages }.execute(database)
        }

        let application = Server.makeApplication(database: database)
        try await application.test(.router) { client in
            try await client.execute(
                uri: "/workspaces/\(workspace.id)/sessions/\(session.id)/model-history",
                method: .get
            ) { response in
                #expect(response.status == .ok)
                let history = try JSONDecoder.conductor.decode(
                    Session.ModelHistory.self,
                    from: Data(response.body.readableBytesView)
                )
                #expect(history.hasMessages)
                #expect(history.lastUsedModel == .gpt_5_6_sol)
            }

            try await client.execute(
                uri: "/workspaces/\(workspace.id)/sessions/\(neverUsedSession.id)/model-history",
                method: .get
            ) { response in
                #expect(response.status == .ok)
                let history = try JSONDecoder.conductor.decode(
                    Session.ModelHistory.self,
                    from: Data(response.body.readableBytesView)
                )
                #expect(!history.hasMessages)
                #expect(history.lastUsedModel == nil)
            }

            try await client.execute(
                uri: "/workspaces/other/sessions/\(session.id)/model-history",
                method: .get
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test("Session changes return success after persistence")
    func mutations() async throws {
        let (database, workspace, session) = try await sessionRouteDatabase()
        let uiHook = WorkspaceUIHook.liveValue
        let connection = await uiHook.connect()
        let browser = Task {
            var events = connection.events.makeAsyncIterator()

            let rename = try sessionCommand(from: #require(await events.next()))
            #expect(rename.sessionID == session.id)
            #expect(rename.workspaceID == workspace.id)
            #expect(rename.title == "Renamed chat")
            let title = "Renamed chat"
            try await database.write { database in
                try Session
                    .find(session.id)
                    .update { $0.title = #bind(title) }
                    .execute(database)
            }
            #expect(
                await uiHook.didCompleteCommand(
                    result: WorkspaceUIHook.CommandResult(
                        requestID: rename.requestID,
                        error: nil
                    )
                )
            )

            let close = try sessionCommand(from: #require(await events.next()))
            #expect(close.sessionID == session.id)
            #expect(close.workspaceID == workspace.id)
            #expect(close.hidden == true)
            try await database.write { database in
                try Session
                    .find(session.id)
                    .update { $0.isHidden = true }
                    .execute(database)
            }
            #expect(
                await uiHook.didCompleteCommand(
                    result: WorkspaceUIHook.CommandResult(
                        requestID: close.requestID,
                        error: nil
                    )
                )
            )

            let restore = try sessionCommand(from: #require(await events.next()))
            #expect(restore.sessionID == session.id)
            #expect(restore.workspaceID == workspace.id)
            #expect(restore.hidden == false)
            try await database.write { database in
                try Session
                    .find(session.id)
                    .update { $0.isHidden = false }
                    .execute(database)
            }
            #expect(
                await uiHook.didCompleteCommand(
                    result: WorkspaceUIHook.CommandResult(
                        requestID: restore.requestID,
                        error: nil
                    )
                )
            )
        }

        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0.workspaceUIHook = uiHook
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                for (body, expectedStatus) in [
                    (#"{"title":" Renamed chat "}"#, HTTPResponse.Status.noContent),
                    (#"{"hidden":true}"#, .noContent),
                    (#"{"hidden":false}"#, .noContent),
                ] {
                    try await client.execute(
                        uri: "/workspaces/\(workspace.id)/sessions/\(session.id)",
                        method: .patch,
                        body: ByteBuffer(string: body)
                    ) { response in
                        #expect(response.status == expectedStatus)
                    }
                }
            }
        }
        try await browser.value
    }

    @Test("Restore times out while the session remains hidden")
    func restorePersistenceTimeout() async throws {
        let (database, workspace, session) = try await sessionRouteDatabase()
        try await database.write { database in
            try Session
                .find(session.id)
                .update { $0.isHidden = true }
                .execute(database)
        }
        let uiHook = WorkspaceUIHook.liveValue
        let connection = await uiHook.connect()
        let browser = Task {
            var events = connection.events.makeAsyncIterator()
            let restore = try sessionCommand(from: #require(await events.next()))
            #expect(restore.hidden == false)
            #expect(
                await uiHook.didCompleteCommand(
                    result: WorkspaceUIHook.CommandResult(
                        requestID: restore.requestID,
                        error: nil
                    )
                )
            )
        }

        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0.workspaceUIHook = uiHook
        } operation: {
            let application = Server.makeApplication(
                database: database,
                uiCommandTimeout: .milliseconds(20)
            )
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/\(workspace.id)/sessions/\(session.id)",
                    method: .patch,
                    body: ByteBuffer(string: #"{"hidden":false}"#)
                ) { response in
                    #expect(response.status == .gatewayTimeout)
                }
            }
        }
        try await browser.value
    }

    @Test("Close persistence timeout starts after browser cancellation completes")
    func slowClose() async throws {
        let (database, workspace, session) = try await sessionRouteDatabase()
        let uiHook = WorkspaceUIHook.liveValue
        let connection = await uiHook.connect()
        let browser = Task {
            var events = connection.events.makeAsyncIterator()
            let close = try sessionCommand(from: #require(await events.next()))
            #expect(close.hidden == true)

            try await Task.sleep(for: .milliseconds(40))
            try await database.write { database in
                try Session
                    .find(session.id)
                    .update { $0.isHidden = true }
                    .execute(database)
            }
            #expect(
                await uiHook.didCompleteCommand(
                    result: WorkspaceUIHook.CommandResult(
                        requestID: close.requestID,
                        error: nil
                    )
                )
            )
        }

        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0.workspaceUIHook = uiHook
        } operation: {
            let application = Server.makeApplication(
                database: database,
                uiCommandTimeout: .milliseconds(20)
            )
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/\(workspace.id)/sessions/\(session.id)",
                    method: .patch,
                    body: ByteBuffer(string: #"{"hidden":true}"#)
                ) { response in
                    #expect(response.status == .noContent)
                }
            }
        }
        try await browser.value
    }

    @Test("Session changes require one supported field and a connected hook")
    func invalidRequests() async throws {
        let (database, workspace, session) = try await sessionRouteDatabase()
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0.workspaceUIHook = .liveValue
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                for body in [
                    "{}",
                    #"{"hidden":"false"}"#,
                    #"{"title":" "}"#,
                    #"{"title":"Name","hidden":true}"#,
                ] {
                    try await client.execute(
                        uri: "/workspaces/\(workspace.id)/sessions/\(session.id)",
                        method: .patch,
                        body: ByteBuffer(string: body)
                    ) { response in
                        #expect(response.status == .badRequest)
                    }
                }

                try await client.execute(
                    uri: "/workspaces/\(workspace.id)/sessions/\(session.id)",
                    method: .patch,
                    body: ByteBuffer(string: #"{"hidden":true}"#)
                ) { response in
                    #expect(response.status == .serviceUnavailable)
                }
            }
        }
    }
}

private struct SessionCommand: Decodable {
    let requestID: UUID
    let sessionID: Session.ID
    let workspaceID: Workspace.ID
    let hidden: Bool?
    let title: String?

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case sessionID = "sessionId"
        case workspaceID = "workspaceId"
        case hidden
        case title
    }
}

private func sessionCommand(from event: String) throws -> SessionCommand {
    let json = event
        .dropFirst("data: ".count)
        .dropLast(2)
    return try JSONDecoder().decode(SessionCommand.self, from: Data(json.utf8))
}

private func sessionRouteDatabase() async throws -> (DatabaseQueue, Workspace, Session) {
    let database = try testConductorDatabase()
    let date = Date(timeIntervalSince1970: 1_783_555_200)
    let workspace = Workspace(
        id: "workspace-1",
        createdAt: date,
        updatedAt: date
    )
    let session = Session(
        id: "session-1",
        workspaceID: workspace.id,
        title: "Original chat",
        agentType: .codex,
        isHidden: false,
        createdAt: "2026-07-19T00:00:00Z",
        updatedAt: "2026-07-19T00:00:00Z",
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
    return (database, workspace, session)
}
