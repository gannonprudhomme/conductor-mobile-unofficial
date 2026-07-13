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
    @Test("State equality tracks completed presentation rebuilds but not derived caches")
    func stateEquality() throws {
        try withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let original = Chat.State(session: try makeSession())
            var changedCaches = original
            changedCaches.turns = []
            changedCaches.rows = []

            #expect(original == changedCaches)

            changedCaches.displayedContentRevision += 1
            #expect(original != changedCaches)
        }
    }

    @Test("Displayed content scrolls initially and only follows later updates from the bottom")
    func displayedContentScrolling() {
        let scrollState = ChatView.ScrollState()
        scrollState.isBottomMarkerVisible = false

        #expect(scrollState.displayedContentChanged(hasRows: false) == .none)
        #expect(!scrollState.hasDisplayedContent)
        #expect(scrollState.displayedContentChanged(hasRows: true) == .initial)
        #expect(scrollState.hasDisplayedContent)
        #expect(scrollState.displayedContentChanged(hasRows: true) == .none)

        scrollState.isBottomMarkerVisible = true
        #expect(scrollState.displayedContentChanged(hasRows: true) == .subsequent)
    }

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
                $0.displayedContentRevision += 1
            }
            #expect(try #require(store.state.turns).isEmpty)
            #expect(try #require(store.state.rows).isEmpty)
            #expect(store.state.displayedContentRevision == 1)
            #expect(requestCount.value == 1)

            await clock.advance(by: .seconds(1))
            await store.receive(\.loadMessagesFailed)
            #expect(requestCount.value == 2)

            await task.cancel()
        }
    }

    @Test("Task skips unchanged message snapshots regardless of transport order")
    func taskSkipsUnchangedMessages() async throws {
        let database = try appDatabase()
        let session = try makeSession()
        var mutableEarlyMessage = try makeMessage(
            id: "early",
            sessionID: session.id,
            createdAt: "2026-07-09 01:00:00"
        )
        mutableEarlyMessage.role = .user
        mutableEarlyMessage.turnID = "turn-1"
        let earlyMessage = mutableEarlyMessage

        var mutableLateMessage = try makeMessage(
            id: "late",
            sessionID: session.id,
            createdAt: "2026-07-09 02:00:00"
        )
        mutableLateMessage.role = .user
        mutableLateMessage.turnID = "turn-1"
        let lateMessage = mutableLateMessage

        try await database.write { db in
            try Message.upsert { [earlyMessage, lateMessage] }.execute(db)
        }
        let baselineChangeCount = try await database.write { $0.totalChangesCount }

        var mutableUpdatedEarlyMessage = earlyMessage
        mutableUpdatedEarlyMessage.content = "Updated early message"
        let updatedEarlyMessage = mutableUpdatedEarlyMessage
        let clock = TestClock()
        let (firstPollGate, firstPollContinuation) = AsyncStream.makeStream(of: Void.self)
        let requestCount = LockIsolated(0)
        let store = TestStore(initialState: Chat.State(session: session)) {
            Chat()
        } withDependencies: {
            $0.continuousClock = clock
            $0.defaultDatabase = database
            $0.desktopClient.fetchMessages = { _, _ in
                switch requestCount.withValue({ $0 += 1; return $0 }) {
                case 1:
                    for await _ in firstPollGate { break }
                    return [lateMessage, updatedEarlyMessage]
                case 2:
                    return [updatedEarlyMessage, lateMessage]
                default:
                    throw TestError()
                }
            }
        }

        let task = await store.send(.task)

        await store.receive(\.messagesUpdated) {
            $0.displayedContentRevision += 1
        }
        try expectHumanPresentationCaches(
            store.state,
            turnID: "turn-1",
            startedAt: earlyMessage.createdAt,
            messages: [
                .init(id: "early", content: "Message early"),
                .init(id: "late", content: "Message late"),
            ]
        )
        firstPollContinuation.yield()
        firstPollContinuation.finish()
        await store.receive(\.messagesUpdated) {
            $0.displayedContentRevision += 1
        }
        try expectHumanPresentationCaches(
            store.state,
            turnID: "turn-1",
            startedAt: earlyMessage.createdAt,
            messages: [
                .init(id: "early", content: "Updated early message"),
                .init(id: "late", content: "Message late"),
            ]
        )
        #expect(store.state.displayedContentRevision == 2)

        await clock.advance(by: .seconds(1))
        #expect(requestCount.value == 2)
        #expect(store.state.displayedContentRevision == 2)

        await clock.advance(by: .seconds(1))
        await store.receive(\.loadMessagesFailed)
        #expect(requestCount.value == 3)

        let storedMessages = try await database.read { db in
            try Message
                .where { $0.sessionID.eq(session.id) }
                .order { ($0.createdAt, $0.id) }
                .fetchAll(db)
        }
        expectNoDifference(storedMessages, [updatedEarlyMessage, lateMessage])
        #expect(
            try await database.write { $0.totalChangesCount }
                == baselineChangeCount + 2
        )

        await task.cancel()
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
                $0.displayedContentRevision += 1
            }
            try expectHumanPresentationCaches(
                store.state,
                turnID: "turn-1",
                startedAt: message.createdAt,
                messages: [.init(id: "human-1", content: "Hello")]
            )

            await store.send(.sessionStatusChanged(.working))
            #expect(store.state.displayedContentRevision == 1)
            expectNoDifference(
                try #require(store.state.rows).map(DisplayedRowProjection.init),
                [
                    .human(id: "human-1", content: "Hello"),
                    .turnInProgress(id: "turn-1", startedAt: message.createdAt),
                ]
            )

            await store.send(.sessionStatusChanged(.idle))
            #expect(store.state.displayedContentRevision == 1)
            try expectHumanPresentationCaches(
                store.state,
                turnID: "turn-1",
                startedAt: message.createdAt,
                messages: [.init(id: "human-1", content: "Hello")]
            )
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
            await store.receive(\.sendMessageResponse) {
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
            await store.receive(\.sendMessageResponse) {
                $0.isMessageSendInFlight = false
            }
        }
    }

    @Test("Stopping a working session re-enables Stop after acknowledgement")
    func stopSessionSucceeds() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let session = try makeSession(status: "working")
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            } withDependencies: {
                $0.desktopClient.stopSession = { workspaceID, sessionID in
                    #expect(workspaceID == session.workspaceID)
                    #expect(sessionID == session.id)
                }
            }

            await store.send(.stopButtonTapped) {
                $0.isStopInFlight = true
            }
            await store.receive(\.stopSessionResponse) {
                $0.isStopInFlight = false
            }
        }
    }

    @Test("A stop failure re-enables the stop button")
    func stopSessionFails() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let session = try makeSession(status: "working")
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            } withDependencies: {
                $0.desktopClient.stopSession = { _, _ in
                    throw TestError()
                }
            }

            await store.send(.stopButtonTapped) {
                $0.isStopInFlight = true
            }
            await store.receive(\.stopSessionResponse) {
                $0.isStopInFlight = false
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

private func makeSession(status: String = "idle") throws -> Session {
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
              "status": "\(status)",
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

private enum DisplayedRowProjection: Equatable {
    case human(id: String, content: String)
    case assistant(id: String)
    case turnInProgress(id: String, startedAt: Date)

    init(_ row: DisplayedChatRow) {
        switch row {
        case .humanMessage(let message):
            self = .human(id: message.id, content: message.content)
        case .assistantTextChunk, .assistantToolCall, .assistantError:
            self = .assistant(id: row.id)
        case .turnInProgress(let progress):
            self = .turnInProgress(id: progress.id, startedAt: progress.startedAt)
        }
    }
}

private func expectHumanPresentationCaches(
    _ state: Chat.State,
    turnID: String,
    startedAt: Date,
    messages expectedMessages: [Turn.Row.HumanMessageRow]
) throws {
    let turns = try #require(state.turns)
    let turn = try #require(turns.first)
    #expect(turns.count == 1)
    #expect(turn.id == turnID)
    #expect(turn.startedAt == startedAt)

    let messages = turn.rows.compactMap { row -> Turn.Row.HumanMessageRow? in
        guard case let .humanMessageRow(message) = row else {
            return nil
        }
        return message
    }
    #expect(messages.count == turn.rows.count)
    expectNoDifference(messages, expectedMessages)

    expectNoDifference(
        try #require(state.rows).map(DisplayedRowProjection.init),
        expectedMessages.map { .human(id: $0.id, content: $0.content) }
    )
}
