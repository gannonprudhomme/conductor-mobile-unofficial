//
//  QueueRouteTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/16/26.
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

struct QueueRouteTests {
    @Test("Editing persists the message before restoring a running queue")
    func editQueuedMessage() async throws {
        let (database, workspace, session, _) = try await queueRouteDatabase()
        var uiHook = WorkspaceUIHook.liveValue
        uiHook.setQueuePaused = { sessionID, isPaused, waitUntilChangeAvailableInDatabase in
            try await database.write { database in
                try Session
                    .find(sessionID)
                    .update {
                        $0.queuePausedAt = #bind(
                            isPaused ? "2026-07-18T09:00:00Z" : nil
                        )
                    }
                    .execute(database)
                if !isPaused {
                    try Message
                        .find("message-1")
                        .update { $0.sentAt = #bind(Date()) }
                        .execute(database)
                }
            }
            try await waitUntilChangeAvailableInDatabase()
        }
        uiHook.editQueuedMessage = {
            sessionID,
            messageID,
            content,
            shouldResumeQueue,
            waitUntilChangeAvailableInDatabase in
            #expect(!shouldResumeQueue)
            try await database.write { database in
                try Message
                    .find(messageID)
                    .update { $0.content = #bind(content) }
                    .execute(database)
            }
            try await waitUntilChangeAvailableInDatabase()
        }

        try await withDependencies {
            $0.workspaceUIHook = uiHook
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: queueURI(workspaceID: workspace.id, sessionID: session.id)
                        + "/message-1/edit",
                    method: .post
                ) { response in
                    #expect(response.status == .ok)
                    let edit = try JSONDecoder.conductor.decode(
                        BeginEditResponse.self,
                        from: Data(response.body.readableBytesView)
                    )
                    #expect(edit.message.content == "First")
                    #expect(edit.shouldResumeQueue)
                }

                try await client.execute(
                    uri: queueURI(workspaceID: workspace.id, sessionID: session.id)
                        + "/message-1",
                    method: .patch,
                    body: ByteBuffer(
                        string: #"{"content":"Updated","resume_queue":true}"#
                    )
                ) { response in
                    #expect(response.status == .noContent)
                }
            }
        }

        let result = try await database.read { database in
            (
                try Message.find("message-1").fetchOne(database)?.content,
                try Session.find(session.id).fetchOne(database)?.queuePausedAt,
                try Message.find("message-1").fetchOne(database)?.sentAt
            )
        }
        #expect(result.0 == "Updated")
        #expect(result.1 == nil)
        #expect(result.2 != nil)
    }

    @Test("Cancelling an edit resumes a paused queue")
    func resumeQueue() async throws {
        let (database, workspace, session, _) = try await queueRouteDatabase()
        try await database.write { database in
            try Session
                .find(session.id)
                .update { $0.queuePausedAt = #bind("2026-07-18T09:00:00Z") }
                .execute(database)
        }
        var uiHook = WorkspaceUIHook.liveValue
        uiHook.setQueuePaused = { sessionID, isPaused, waitUntilChangeAvailableInDatabase in
            #expect(!isPaused)
            try await database.write { database in
                try Session
                    .find(sessionID)
                    .update { $0.queuePausedAt = #bind(nil as String?) }
                    .execute(database)
            }
            try await waitUntilChangeAvailableInDatabase()
        }

        try await withDependencies {
            $0.workspaceUIHook = uiHook
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: queueURI(workspaceID: workspace.id, sessionID: session.id)
                        + "/resume",
                    method: .post
                ) { response in
                    #expect(response.status == .noContent)
                }
            }
        }

        let queuePausedAt = try await database.read { database in
            try Session.find(session.id).fetchOne(database)?.queuePausedAt
        }
        #expect(queuePausedAt == nil)
    }

    @Test("Deleting and steering queued messages use Conductor and wait for persistence")
    func deleteAndSteerQueuedMessages() async throws {
        let (database, workspace, session, _) = try await queueRouteDatabase()
        var uiHook = WorkspaceUIHook.liveValue
        uiHook.deleteQueuedMessage = {
            sessionID,
            messageID,
            waitUntilChangeAvailableInDatabase in
            #expect(sessionID == session.id)
            #expect(messageID == "message-1")
            try await database.write { database in
                try Message
                    .find(messageID)
                    .update {
                        $0.cancelledAt = #bind("2026-07-24T10:00:00Z")
                    }
                    .execute(database)
            }
            try await waitUntilChangeAvailableInDatabase()
        }
        uiHook.steerQueuedMessage = {
            sessionID,
            messageID,
            waitUntilChangeAvailableInDatabase in
            #expect(sessionID == session.id)
            #expect(messageID == "message-2")
            try await database.write { database in
                try Message
                    .find(messageID)
                    .update { $0.sentAt = #bind(Date()) }
                    .execute(database)
            }
            try await waitUntilChangeAvailableInDatabase()
        }

        try await withDependencies {
            $0.workspaceUIHook = uiHook
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: queueURI(workspaceID: workspace.id, sessionID: session.id)
                        + "/message-1",
                    method: .delete
                ) { response in
                    #expect(response.status == .noContent)
                }

                try await client.execute(
                    uri: queueURI(workspaceID: workspace.id, sessionID: session.id)
                        + "/message-2/steer",
                    method: .post
                ) { response in
                    #expect(response.status == .noContent)
                }
            }
        }

        let result = try await database.read { database in
            (
                try Message.find("message-1").fetchOne(database)?.cancelledAt,
                try Message.find("message-2").fetchOne(database)?.sentAt
            )
        }
        #expect(result.0 == "2026-07-24T10:00:00Z")
        #expect(result.1 != nil)
    }

    @Test("A message consumed immediately after pausing does not leave the queue paused")
    func editRaceRestoresQueue() async throws {
        let (database, workspace, session, _) = try await queueRouteDatabase()
        var uiHook = WorkspaceUIHook.liveValue
        uiHook.setQueuePaused = { sessionID, isPaused, waitUntilChangeAvailableInDatabase in
            try await database.write { database in
                try Session
                    .find(sessionID)
                    .update {
                        $0.queuePausedAt = #bind(
                            isPaused ? "2026-07-18T09:00:00Z" : nil
                        )
                    }
                    .execute(database)
            }
            try await waitUntilChangeAvailableInDatabase()
            if isPaused {
                try await database.write { database in
                    try Message
                        .find("message-1")
                        .update { $0.sentAt = #bind(Date()) }
                        .execute(database)
                }
            }
        }

        try await withDependencies {
            $0.workspaceUIHook = uiHook
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: queueURI(workspaceID: workspace.id, sessionID: session.id)
                        + "/message-1/edit",
                    method: .post
                ) { response in
                    #expect(response.status == .conflict)
                }
            }
        }

        let queuePausedAt = try await database.read { database in
            try Session.find(session.id).fetchOne(database)?.queuePausedAt
        }
        #expect(queuePausedAt == nil)
    }

    @Test("Queue PATCH returns only after Conductor persists the requested order")
    func liveReorder() async throws {
        let (database, workspace, session, messages) = try await queueRouteDatabase()
        let uiHook = WorkspaceUIHook.liveValue
        let connection = await uiHook.connect()
        let browser = Task {
            var events = connection.events.makeAsyncIterator()
            let event = try #require(await events.next())
            let data = try #require(
                event
                    .split(separator: "\n")
                    .first?
                    .dropFirst("data: ".count)
                    .data(using: .utf8)
            )
            let command = try JSONDecoder().decode(QueueCommand.self, from: data)
            #expect(command.sessionId == session.id)
            #expect(command.orderedIds == messages.reversed().map(\.id))

            try await database.write { database in
                for (index, messageID) in command.orderedIds.enumerated() {
                    try Message
                        .find(messageID)
                        .update { $0.queueOrder = #bind(index + 1) }
                        .execute(database)
                }
            }
        }

        try await withDependencies {
            $0.workspaceUIHook = uiHook
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: queueURI(workspaceID: workspace.id, sessionID: session.id),
                    method: .patch,
                    body: ByteBuffer(
                        string: #"{"message_ids":["message-2","message-1"]}"#
                    )
                ) { response in
                    #expect(response.status == .noContent)
                }
            }
        }
        try await browser.value

        let persistedOrder = try await database.read { database in
            try Message
                .where { $0.sessionID.eq(session.id) }
                .order { $0.queueOrder.asc() }
                .fetchAll(database)
                .map(\.id)
        }
        #expect(persistedOrder == ["message-2", "message-1"])
    }

    @Test("Queue PATCH rejects stale or invalid orders before contacting Conductor")
    func invalidOrders() async throws {
        let (database, workspace, session, _) = try await queueRouteDatabase()
        let calls = LockIsolated(0)
        var uiHook = WorkspaceUIHook.liveValue
        uiHook.reorderQueue = { _, _, _ in
            calls.withValue { $0 += 1 }
        }

        try await withDependencies {
            $0.workspaceUIHook = uiHook
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                for (body, status) in [
                    ("{}", HTTPResponse.Status.badRequest),
                    (#"{"message_ids":[]}"#, .badRequest),
                    (#"{"message_ids":["message-1","message-1"]}"#, .badRequest),
                    (#"{"message_ids":["message-1"]}"#, .conflict),
                    (#"{"message_ids":["message-1","missing"]}"#, .conflict),
                ] {
                    try await client.execute(
                        uri: queueURI(workspaceID: workspace.id, sessionID: session.id),
                        method: .patch,
                        body: ByteBuffer(string: body)
                    ) { response in
                        #expect(response.status == status)
                    }
                }

                try await client.execute(
                    uri: queueURI(workspaceID: workspace.id, sessionID: "missing"),
                    method: .patch,
                    body: ByteBuffer(
                        string: #"{"message_ids":["message-2","message-1"]}"#
                    )
                ) { response in
                    #expect(response.status == .notFound)
                }
            }
        }

        #expect(calls.value == 0)
    }

    @Test("Queue PATCH has no SQLite fallback when Conductor's hook is disconnected")
    func disconnectedHook() async throws {
        let (database, workspace, session, _) = try await queueRouteDatabase()

        try await withDependencies {
            $0.workspaceUIHook = .liveValue
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: queueURI(workspaceID: workspace.id, sessionID: session.id),
                    method: .patch,
                    body: ByteBuffer(
                        string: #"{"message_ids":["message-2","message-1"]}"#
                    )
                ) { response in
                    #expect(response.status == .serviceUnavailable)
                }
            }
        }

        let persistedOrder = try await database.read { database in
            try Message
                .where { $0.sessionID.eq(session.id) }
                .order { $0.queueOrder.asc() }
                .fetchAll(database)
                .map(\.id)
        }
        #expect(persistedOrder == ["message-1", "message-2"])
    }
}

private func queueRouteDatabase() async throws -> (
    DatabaseQueue,
    Workspace,
    Session,
    [Message]
) {
    let database = try testConductorDatabase()
    let date = Date(timeIntervalSince1970: 1_783_555_200)
    let workspace = Workspace(id: "workspace", createdAt: date, updatedAt: date)
    let session = Session(
        id: "session",
        workspaceID: workspace.id,
        title: "Chat",
        agentType: .codex,
        isHidden: false,
        createdAt: "2026-07-09T00:00:00Z",
        updatedAt: "2026-07-09T00:00:00Z",
        lastUserMessageAt: nil,
        status: .working,
        model: .init(rawValue: "gpt-5"),
        unreadCount: 0,
        freshlyCompacted: 0,
        contextTokenCount: 0
    )
    let messages = [
        Message(
            id: "message-1",
            sessionID: session.id,
            role: .user,
            content: "First",
            createdAt: date,
            queueOrder: 1
        ),
        Message(
            id: "message-2",
            sessionID: session.id,
            role: .user,
            content: "Second",
            createdAt: date.addingTimeInterval(1),
            queueOrder: 2
        ),
    ]
    try await database.write { database in
        try Workspace.insert { workspace }.execute(database)
        try Session.insert { session }.execute(database)
        try Message.insert { messages }.execute(database)
    }
    return (database, workspace, session, messages)
}

private func queueURI(workspaceID: String, sessionID: String) -> String {
    "/workspaces/\(workspaceID)/sessions/\(sessionID)/messages/queue"
}

private struct QueueCommand: Decodable {
    let sessionId: String
    let orderedIds: [String]
}

private struct BeginEditResponse: Decodable {
    let message: Message
    let shouldResumeQueue: Bool

    private enum CodingKeys: String, CodingKey {
        case message
        case shouldResumeQueue = "should_resume_queue"
    }
}
