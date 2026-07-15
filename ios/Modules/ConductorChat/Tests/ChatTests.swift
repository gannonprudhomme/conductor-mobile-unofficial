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
    @Test("State equality tracks presentation changes but not derived caches")
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

            var changedExpansion = original
            changedExpansion.expandedSummaryIDs.insert("turn-1:human-1")
            #expect(original != changedExpansion)

            var finishedLoading = original
            finishedLoading.isLoadingMessages = false
            #expect(original != finishedLoading)
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

    @Test("Task observes the selected session, reconnects after failure, and cancels")
    func task() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let clock = TestClock()
            let (firstStream, firstContinuation) = AsyncThrowingStream<
                [Message],
                any Error
            >.makeStream()
            let (secondStream, secondContinuation) = AsyncThrowingStream<
                [Message],
                any Error
            >.makeStream()
            let connectionCount = LockIsolated(0)
            let session = try makeSession()
            let secondConnectionCancelled = LockIsolated(false)
            secondContinuation.onTermination = { termination in
                guard case .cancelled = termination else {
                    return
                }

                secondConnectionCancelled.setValue(true)
            }
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            } withDependencies: {
                $0.continuousClock = clock
                $0.desktopClient.observeMessages = { workspaceID, sessionID in
                    #expect(workspaceID == session.workspaceID)
                    #expect(sessionID == session.id)

                    let count = connectionCount.withValue {
                        $0 += 1
                        return $0
                    }
                    return switch count {
                    case 1:
                        firstStream

                    default:
                        secondStream
                    }
                }
            }

            let task = await store.send(.task)

            await store.receive(\.messagesUpdated) {
                $0.displayedContentRevision += 1
            }
            #expect(try #require(store.state.turns).isEmpty)
            #expect(try #require(store.state.rows).isEmpty)
            #expect(store.state.displayedContentRevision == 1)
            #expect(connectionCount.value == 1)

            firstContinuation.yield([])
            await store.receive(\.initialMessagesResponse) {
                $0.isLoadingMessages = false
                $0.displayedContentRevision += 1
            }

            firstContinuation.finish(throwing: TestError())
            await store.receive(\.loadMessagesFailed)
            #expect(connectionCount.value == 1)

            await clock.advance(by: .seconds(1))
            #expect(connectionCount.value == 2)

            await task.cancel()
            #expect(secondConnectionCancelled.value)
        }
    }

    @Test("Task ingests initial and changed message batches")
    func taskIngestsMessageBatches() async throws {
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
        var mutableUpdatedLateMessage = lateMessage
        mutableUpdatedLateMessage.content = "Updated late message"
        let updatedLateMessage = mutableUpdatedLateMessage
        let (stream, continuation) = AsyncThrowingStream<
            [Message],
            any Error
        >.makeStream()
        let store = TestStore(initialState: Chat.State(session: session)) {
            Chat()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.desktopClient.observeMessages = { workspaceID, sessionID in
                #expect(workspaceID == session.workspaceID)
                #expect(sessionID == session.id)
                return stream
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

        continuation.yield([lateMessage, updatedEarlyMessage])
        await store.receive(\.initialMessagesResponse) {
            $0.isLoadingMessages = false
            $0.displayedContentRevision += 1
        }
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
        #expect(store.state.displayedContentRevision == 3)

        continuation.yield([updatedLateMessage])
        await store.receive(\.messagesUpdated) {
            $0.displayedContentRevision += 1
        }
        try expectHumanPresentationCaches(
            store.state,
            turnID: "turn-1",
            startedAt: earlyMessage.createdAt,
            messages: [
                .init(id: "early", content: "Updated early message"),
                .init(id: "late", content: "Updated late message"),
            ]
        )
        #expect(store.state.displayedContentRevision == 4)

        let storedMessages = try await database.read { db in
            try Message
                .where { $0.sessionID.eq(session.id) }
                .order { ($0.createdAt, $0.id) }
                .fetchAll(db)
        }
        expectNoDifference(storedMessages, [updatedEarlyMessage, updatedLateMessage])
        #expect(
            try await database.write { $0.totalChangesCount }
                == baselineChangeCount + 3
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

    @Test("An empty initial response replaces cached presentation before loading finishes")
    func emptyInitialResponse() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            var message = try makeMessage(
                id: "cached",
                sessionID: "session-1",
                createdAt: "2026-07-09 01:00:00"
            )
            message.role = .user
            message.turnID = "turn-1"
            let session = try makeSession()
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            }

            await store.send(.messagesUpdated([message])) {
                $0.displayedContentRevision += 1
            }
            #expect(store.state.isLoadingMessages)

            await store.send(.initialMessagesResponse([])) {
                $0.isLoadingMessages = false
                $0.displayedContentRevision += 1
            }
            #expect(try #require(store.state.turns).isEmpty)
            #expect(try #require(store.state.rows).isEmpty)
        }
    }

    @Test("An initial response preserves a canonical message received while loading")
    func initialResponsePreservesCanonicalMessage() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let session = Session.preview()
            let message = Message(
                id: "message-1",
                sessionID: session.id,
                role: .user,
                content: "Run the tests.",
                createdAt: Date(timeIntervalSince1970: 1_783_558_800),
                turnID: "turn-1"
            )
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            }

            await store.send(
                .messageConfirmed(
                    sessionID: session.id,
                    message: message
                )
            ) {
                $0.confirmedMessagesAwaitingInitialSnapshot = [message]
            }
            await store.send(.initialMessagesResponse([])) {
                $0.confirmedMessagesAwaitingInitialSnapshot = []
                $0.isLoadingMessages = false
                $0.displayedContentRevision += 1
            }
            try expectHumanPresentationCaches(
                store.state,
                turnID: "turn-1",
                startedAt: message.createdAt,
                messages: [.init(id: message.id, content: "Run the tests.")]
            )
        }
    }

    @Test("Sending persists the canonical message before completing")
    func messageSendSucceeds() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            @Dependency(\.defaultDatabase) var database

            let session = Session.preview(status: .working)
            let sentMessage = Message(
                id: "message-1",
                sessionID: session.id,
                role: .user,
                content: "Please run the tests.",
                createdAt: Date(timeIntervalSince1970: 1_783_558_800),
                turnID: "turn-1"
            )
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            } withDependencies: {
                $0.desktopClient.sendMessage = { workspaceID, sessionID, message in
                    #expect(workspaceID == session.workspaceID)
                    #expect(sessionID == session.id)
                    #expect(message == "Please run the tests.")
                    return sentMessage
                }
            }

            await store.send(.binding(.set(\.messageDraft, "  Please run the tests.  "))) {
                $0.messageDraft = "  Please run the tests.  "
            }
            await store.send(.sendButtonTapped) {
                $0.isMessageSendInFlight = true
            }
            await store.receive(\.messageConfirmed) {
                $0.confirmedMessagesAwaitingInitialSnapshot = [sentMessage]
            }
            await store.receive(\.sendMessageResponse) {
                $0.messageDraft = ""
                $0.isMessageSendInFlight = false
            }
            await store.finish()

            let persistedMessage = try await database.read { database in
                try Message.find(sentMessage.id).fetchOne(database)
            }
            expectNoDifference(persistedMessage, sentMessage)
        }
    }

    @Test("A legacy send response still completes successfully")
    func legacyMessageSendSucceeds() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let session = Session.preview()
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            } withDependencies: {
                $0.desktopClient.sendMessage = { _, _, _ in nil }
            }

            await store.send(.binding(.set(\.messageDraft, "Run the tests."))) {
                $0.messageDraft = "Run the tests."
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

    @Test("A send response preserves a draft edited while the request was in flight")
    func editedDraftIsPreserved() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let session = Session.preview()
            let (responses, responseContinuation) = AsyncStream<Message?>.makeStream()
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            } withDependencies: {
                $0.desktopClient.sendMessage = { _, _, _ in
                    for await response in responses {
                        return response
                    }
                    throw TestError()
                }
            }

            await store.send(.binding(.set(\.messageDraft, "Run the tests."))) {
                $0.messageDraft = "Run the tests."
            }
            await store.send(.sendButtonTapped) {
                $0.isMessageSendInFlight = true
            }
            await store.send(.binding(.set(\.messageDraft, "Only run unit tests."))) {
                $0.messageDraft = "Only run unit tests."
            }

            responseContinuation.yield(Optional<Message>.none)
            await store.receive(\.sendMessageResponse) {
                $0.isMessageSendInFlight = false
            }
            responseContinuation.finish()
            await store.finish()
        }
    }

    @Test("An observed message wins over the HTTP response with the same ID")
    func observedMessageWins() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            @Dependency(\.defaultDatabase) var database

            let session = Session.preview()
            let observedMessage = Message(
                id: "message-1",
                sessionID: session.id,
                role: .user,
                content: "Observed canonical content",
                createdAt: Date(timeIntervalSince1970: 1_783_558_801),
                turnID: "turn-1"
            )
            let responseMessage = Message(
                id: observedMessage.id,
                sessionID: session.id,
                role: .user,
                content: "Run the tests.",
                createdAt: Date(timeIntervalSince1970: 1_783_558_800),
                turnID: "turn-1"
            )
            try await database.write { database in
                try Message.insert { observedMessage }.execute(database)
            }
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            } withDependencies: {
                $0.desktopClient.sendMessage = { _, _, _ in responseMessage }
            }

            await store.send(.binding(.set(\.messageDraft, "Run the tests."))) {
                $0.messageDraft = "Run the tests."
            }
            await store.send(.sendButtonTapped) {
                $0.isMessageSendInFlight = true
            }
            await store.receive(\.messageConfirmed) {
                $0.confirmedMessagesAwaitingInitialSnapshot = [responseMessage]
            }
            await store.receive(\.sendMessageResponse) {
                $0.messageDraft = ""
                $0.isMessageSendInFlight = false
            }
            await store.finish()

            let persistedMessage = try await database.read { database in
                try Message.find(observedMessage.id).fetchOne(database)
            }
            expectNoDifference(persistedMessage, observedMessage)
        }
    }

    @Test("A reconciliation failure completes without producing a load failure")
    func messageReconciliationFailureStillCompletes() async throws {
        let database = try appDatabase()
        try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            let session = Session.preview()
            let responseMessage = Message(
                id: "message-1",
                sessionID: session.id,
                role: .user,
                content: "Run the tests.",
                createdAt: Date(timeIntervalSince1970: 1_783_558_800)
            )
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            } withDependencies: {
                $0.desktopClient.sendMessage = { _, _, _ in responseMessage }
            }

            await store.send(.binding(.set(\.messageDraft, "Run the tests."))) {
                $0.messageDraft = "Run the tests."
            }
            try database.close()

            await store.send(.sendButtonTapped) {
                $0.isMessageSendInFlight = true
            }
            await store.receive(\.messageConfirmed) {
                $0.confirmedMessagesAwaitingInitialSnapshot = [responseMessage]
            }
            await store.receive(\.sendMessageResponse) {
                $0.messageDraft = ""
                $0.isMessageSendInFlight = false
            }
            await store.finish()
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

    @Test("Stopping persists the canonical session before completing")
    func stopSessionSucceeds() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            @Dependency(\.defaultDatabase) var database

            let session = Session.preview(status: .working)
            let stoppedSession = Session.preview(
                updatedAt: "2026-07-09T01:00:00Z",
                status: .idle
            )
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            } withDependencies: {
                $0.desktopClient.stopSession = { workspaceID, sessionID in
                    #expect(workspaceID == session.workspaceID)
                    #expect(sessionID == session.id)
                    return stoppedSession
                }
            }

            await store.send(.stopButtonTapped) {
                $0.isStopInFlight = true
            }
            await store.receive(\.stopSessionResponse) {
                $0.isStopInFlight = false
            }
            await store.finish()

            let persistedSession = try await database.read { database in
                try Session.find(stoppedSession.id).fetchOne(database)
            }
            expectNoDifference(persistedSession, stoppedSession)
        }
    }

    @Test("A legacy stop response still completes successfully")
    func legacyStopSessionSucceeds() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let session = Session.preview(status: .working)
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            } withDependencies: {
                $0.desktopClient.stopSession = { _, _ in nil }
            }

            await store.send(.stopButtonTapped) {
                $0.isStopInFlight = true
            }
            await store.receive(\.stopSessionResponse) {
                $0.isStopInFlight = false
            }
        }
    }

    @Test("An observed session wins over an equal or older HTTP response")
    func observedSessionWins() async throws {
        for observedUpdatedAt in [
            "2026-07-09T01:00:00Z",
            "2026-07-09T02:00:00Z",
        ] {
            let database = try appDatabase()
            let observedSession = Session.preview(
                updatedAt: observedUpdatedAt,
                status: .working
            )
            let responseSession = Session.preview(
                updatedAt: "2026-07-09T01:00:00Z",
                status: .idle
            )
            try await database.write { database in
                try Session.insert { observedSession }.execute(database)
            }

            try await withDependencies {
                $0.defaultDatabase = database
            } operation: {
                let store = TestStore(
                    initialState: Chat.State(session: observedSession)
                ) {
                    Chat()
                } withDependencies: {
                    $0.desktopClient.stopSession = { _, _ in responseSession }
                }

                await store.send(.stopButtonTapped) {
                    $0.isStopInFlight = true
                }
                await store.receive(\.stopSessionResponse) {
                    $0.isStopInFlight = false
                }
                await store.finish()

                let persistedSession = try await database.read { database in
                    try Session.find(observedSession.id).fetchOne(database)
                }
                expectNoDifference(persistedSession, observedSession)
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

    @Test("Summary taps rebuild projected rows")
    func turnSummaryTappedUpdatesRows() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let session = try makeSession()
            let turn = Turn(
                id: "turn-1",
                startedAt: Date(timeIntervalSince1970: 1_000),
                rows: [
                    .humanMessageRow(.init(id: "human-1", content: "Build it")),
                    .assistantMessage(
                        .toolCall(
                            messageID: "tool-1",
                            toolCall: .readFile(toolUseID: "tool-1", filePath: "File.swift")
                        )
                    ),
                    .assistantMessage(
                        .text(
                            messageID: "final",
                            content: .init("Done"),
                            isMostRecentTextInTurn: true
                        )
                    ),
                ]
            )
            let summaryID = "turn-1:human-1"
            var state = Chat.State(session: session)
            state.turns = [turn]
            state.updateRows(sessionStatus: .idle)
            let store = TestStore(initialState: state) {
                Chat()
            }

            expectNoDifference(
                try #require(store.state.rows).map(DisplayedRowProjection.init),
                [
                    .human(id: "human-1", content: "Build it"),
                    .turnSummary(id: summaryID, isExpanded: false),
                    .assistant(id: "assistant:final:chunk:0"),
                ]
            )

            await store.send(.turnSummaryTapped(summaryID)) {
                $0.expandedSummaryIDs = [summaryID]
                $0.rows = [turn].flattenedChatRows(
                    activeTurnID: nil,
                    expandedSummaryIDs: [summaryID]
                )
            }
            expectNoDifference(
                try #require(store.state.rows).map(DisplayedRowProjection.init),
                [
                    .human(id: "human-1", content: "Build it"),
                    .turnSummary(id: summaryID, isExpanded: true),
                    .assistant(id: "assistant:tool-1"),
                    .assistant(id: "assistant:final:chunk:0"),
                ]
            )

            await store.send(.turnSummaryTapped(summaryID)) {
                $0.expandedSummaryIDs = []
                $0.rows = [turn].flattenedChatRows(activeTurnID: nil)
            }
            expectNoDifference(
                try #require(store.state.rows).map(DisplayedRowProjection.init),
                [
                    .human(id: "human-1", content: "Build it"),
                    .turnSummary(id: summaryID, isExpanded: false),
                    .assistant(id: "assistant:final:chunk:0"),
                ]
            )
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
    case turnSummary(id: String, isExpanded: Bool)

    init(_ row: DisplayedChatRowWithPadding) {
        self.init(row.content)
    }

    init(_ row: DisplayedChatRow) {
        self = switch row {
        case .humanMessage(let message):
            .human(id: message.id, content: message.content)
        case .assistantTextChunk, .assistantToolCall, .assistantError:
            .assistant(id: row.id)
        case .turnInProgress(let progress):
            .turnInProgress(id: progress.id, startedAt: progress.startedAt)
        case .turnSummary(let summary):
            .turnSummary(id: summary.id, isExpanded: summary.isExpanded)
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
