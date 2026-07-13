//
//  ChatTests.swift
//  ConductorChatTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import ComposableArchitecture
import SharedConductorData
import ConductorMobileData
import CustomDump
import Foundation
import SQLiteData
@testable import ConductorChat
import Testing

@MainActor
struct ChatTests {
    @Test("Messages are limited to the selected session and ordered chronologically")
    func messagesAreScopedAndOrdered() async throws {
        let earlyMessage = try makeMessage(
            id: "early",
            sessionID: "session-1",
            createdAt: "2026-07-09 01:00:00"
        )
        let lateMessage = try makeMessage(
            id: "late",
            sessionID: "session-1",
            createdAt: "2026-07-09 02:00:00"
        )
        let otherMessage = try makeMessage(
            id: "other",
            sessionID: "session-2",
            createdAt: "2026-07-09 00:00:00"
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Message.upsert { lateMessage }.execute(db)
                try Message.upsert { otherMessage }.execute(db)
                try Message.upsert { earlyMessage }.execute(db)
            }
        } operation: {
            let state = Chat.State(session: try makeSession())
            try await state.$messages.load()

            expectNoDifference(
                state.messages,
                [earlyMessage, lateMessage]
            )
        }
    }

    @Test("Task polls the selected session and observes stored messages")
    func task() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let clock = TestClock()
            let requestCount = LockIsolated(0)

            let session = try makeSession()
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            } withDependencies: {
                $0.continuousClock = clock
                $0.desktopClient.fetchMessages = { workspaceID, sessionID in
                    #expect(workspaceID == session.workspaceID)
                    #expect(sessionID == session.id)

                    let count = requestCount.withValue {
                        $0 += 1
                        return $0
                    }
                    if count == 1 {
                        return []
                    }
                    throw TestError()
                }
            }

            let task = await store.send(.task)

            await store.receive(\.messagesUpdated) {
                $0.turns = []
                $0.rows = []
            }
            #expect(requestCount.value == 1)

            await clock.advance(by: .seconds(1))
            await store.receive(\.loadMessagesFailed)
            #expect(requestCount.value == 2)

            await task.cancel()
        }
    }

    @Test("Messages updated parses turns")
    func messagesUpdated() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let message = try JSONDecoder.conductor.decode(
                Message.self,
                from: Data(
                    """
                    {
                      "id": "human-1",
                      "session_id": "session-1",
                      "role": "user",
                      "content": "Hello",
                      "created_at": "2026-07-09 01:00:00",
                      "turn_id": "turn-1"
                    }
                    """.utf8
                )
            )
            let session = try makeSession()
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            }

            await store.send(.messagesUpdated([message])) {
                $0.turns = [
                    Turn(
                        id: "turn-1",
                        startedAt: message.createdAt,
                        rows: [
                            .humanMessageRow(.init(id: "human-1", content: "Hello")),
                        ]
                    ),
                ]
                $0.rows = [
                    .humanMessageRow(.init(id: "human-1", content: "Hello")),
                ]
            }
            await store.send(.sessionStatusChanged(.working)) {
                $0.rows = [
                    .humanMessageRow(.init(id: "human-1", content: "Hello")),
                    .turnInProgress(
                        .init(id: "turn-1", startedAt: message.createdAt)
                    ),
                ]
            }
            await store.send(.sessionStatusChanged(.idle)) {
                $0.rows = [
                    .humanMessageRow(.init(id: "human-1", content: "Hello")),
                ]
            }
        }
    }
    @Test("Sending a message clears the message draft after the desktop accepts it")
    func messageSendSucceeds() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let session = try makeSession()
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            } withDependencies: {
                $0.desktopClient.sendMessage = { workspaceID, sessionID, message in
                    #expect(workspaceID == session.workspaceID)
                    #expect(sessionID == session.id)
                    #expect(message == "Please run the tests.")
                }
            }

            await store.send(.binding(.set(\.messageDraft, "  Please run the tests.  "))) {
                $0.messageDraft = "  Please run the tests.  "
            }
            await store.send(.sendButtonTapped) {
                $0.isMessageSendInFlight = true
            }
            await store.receive(\.sendMessageResponse.success) {
                $0.messageDraft = ""
                $0.isMessageSendInFlight = false
            }
        }
    }

    @Test("A send failure keeps the message draft")
    func messageSendFails() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let session = try makeSession()
            var state = Chat.State(session: session)
            state.messageDraft = "Please try this again."
            let store = TestStore(initialState: state) {
                Chat()
            } withDependencies: {
                $0.desktopClient.sendMessage = { _, _, _ in
                    throw TestError()
                }
            }

            await store.send(.sendButtonTapped) {
                $0.isMessageSendInFlight = true
            }
            await store.receive(\.sendMessageResponse.failure) {
                $0.isMessageSendInFlight = false
            }
        }
    }
}

private func makeMessage(
    id: String,
    sessionID: String,
    createdAt: String
) throws -> Message {
    try JSONDecoder.conductor.decode(
        Message.self,
        from: Data(
            """
            {
              "id": "\(id)",
              "session_id": "\(sessionID)",
              "role": "assistant",
              "content": "Message \(id)",
              "created_at": "\(createdAt)"
            }
            """.utf8
        )
    )
}

private func makeSession() throws -> Session {
    try JSONDecoder().decode(
        Session.self,
        from: Data(
            """
            {
              "id": "session-1",
              "workspace_id": "workspace-1",
              "title": "Chat",
              "agent_type": "codex",
              "is_hidden": false,
              "created_at": "2026-07-09 00:00:00",
              "updated_at": "2026-07-09 00:00:00",
              "status": "idle",
              "model": "gpt-5",
              "unread_count": 0,
              "freshly_compacted": 0,
              "context_token_count": 0
            }
            """.utf8
        )
    )
}

private struct TestError: LocalizedError {
    var errorDescription: String? {
        "Something went wrong."
    }
}
