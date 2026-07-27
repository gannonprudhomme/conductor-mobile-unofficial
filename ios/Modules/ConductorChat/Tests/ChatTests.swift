//
//  ChatTests.swift
//  ConductorChatTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import ComposableArchitecture
import ConductorMobileData
import CustomDump
import Foundation
import SharedConductorData
import Sharing
import SQLiteData
import SwiftUI
@testable import ConductorChat
@testable import ConductorCloud
import Testing
import UIKit

@MainActor
struct ChatTests {
    @Test("The rendered message field edits the chat draft")
    func messageFieldEditsDraft() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let store = Store(
                initialState: Chat.State(
                    session: .preview(),
                    shouldFocusMessageField: true
                )
            ) {
                Chat()
            }
            let hostingController = UIHostingController(
                rootView: ChatView(store: store, directoryName: "repo")
            )
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = hostingController
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(1))
            while firstTextInputResponder(in: hostingController.view) == nil,
                  clock.now < deadline {
                await Task.yield()
            }

            let responder = try #require(firstTextInputResponder(in: hostingController.view))
            responder.insertText("Test message")

            while store.state.messageDraft != "Test message", clock.now < deadline {
                await Task.yield()
            }
            #expect(store.state.messageDraft == "Test message")
        }
    }

    @Test("Connection status follows the shared desktop status")
    func connectionStatus() throws {
        try withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
            try $0.bootstrapDatabase()
        } operation: {
            @Shared(.desktopConnectionStatus) var connectionStatus
            let state = Chat.State(session: try makeSession())

            $connectionStatus.withLock { $0 = .connected }
            expectNoDifference(state.connectionStatus, .connected)

            $connectionStatus.withLock { $0 = .disconnected }
            expectNoDifference(state.connectionStatus, .disconnected)
        }
    }

    @Test("State equality tracks presentation state but not derived caches")
    func stateEquality() throws {
        try withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let original = Chat.State(session: try makeSession())
            var changedCaches = original
            changedCaches.turns = []
            changedCaches.rows = []

            #expect(original == changedCaches)

            var changedExpansion = original
            changedExpansion.expandedSummaryIDs.insert("turn-1:human-1")
            #expect(original != changedExpansion)

            var finishedLoading = original
            finishedLoading.isLoadingMessages = false
            #expect(original != finishedLoading)

            var emptySnapshot = original
            emptySnapshot.isMessageSnapshotEmpty = true
            #expect(original != emptySnapshot)

            emptySnapshot.isLoadingMessages = false
            #expect(emptySnapshot.allowsAgentSwitching)
            emptySnapshot.isMessageSendInFlight = true
            #expect(!emptySnapshot.allowsAgentSwitching)
        }
    }

    @Test("Message drafts are restored per session")
    func messageDraftsAreRestoredPerSession() throws {
        try withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let firstSession = Session.preview(id: "first")
            let secondSession = Session.preview(id: "second")
            let store = TestStore(initialState: Chat.State(session: firstSession)) {
                Chat()
            }

            store.state.$messageDraft.withLock { $0 = "First draft" }

            #expect(Chat.State(session: firstSession).messageDraft == "First draft")
            #expect(Chat.State(session: secondSession).messageDraft.isEmpty)
        }
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
                MessageSyncResponse,
                any Error
            >.makeStream()
            let (secondStream, secondContinuation) = AsyncThrowingStream<
                MessageSyncResponse,
                any Error
            >.makeStream()
            let (connections, connectionContinuation) = AsyncStream<Int>.makeStream()
            var connectionIterator = connections.makeAsyncIterator()
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
                $0.desktopClient.observeMessages = { workspaceID, sessionID, request in
                    #expect(workspaceID == session.workspaceID)
                    #expect(sessionID == session.id)
                    #expect(request.fingerprints.isEmpty)

                    let count = connectionCount.withValue {
                        $0 += 1
                        return $0
                    }
                    connectionContinuation.yield(count)
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
                $0.isMessageSnapshotEmpty = true
            }
            #expect(try #require(store.state.turns).isEmpty)
            #expect(try #require(store.state.rows).isEmpty)
            let firstConnection = await connectionIterator.next()
            #expect(firstConnection == 1)

            firstContinuation.yield(
                MessageSyncResponse(messages: [], deletedMessageIDs: [])
            )
            await store.receive(\.initialMessagesResponse) {
                $0.isLoadingMessages = false
            }

            firstContinuation.finish(throwing: TestError())
            await store.receive(\.loadMessagesFailed)
            #expect(connectionCount.value == 1)

            await clock.advance(by: .seconds(1))
            let secondConnection = await connectionIterator.next()
            #expect(secondConnection == 2)

            await task.cancel()
            #expect(secondConnectionCancelled.value)
            connectionContinuation.finish()
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
            MessageSyncResponse,
            any Error
        >.makeStream()
        let store = TestStore(initialState: Chat.State(session: session)) {
            Chat()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.desktopClient.observeMessages = { workspaceID, sessionID, request in
                #expect(workspaceID == session.workspaceID)
                #expect(sessionID == session.id)
                #expect(request.fingerprints.keys.sorted() == ["early", "late"])
                return stream
            }
        }

        let task = await store.send(.task)

        await store.receive(\.messagesUpdated)
        try expectHumanPresentationCaches(
            store.state,
            turnID: "turn-1",
            startedAt: earlyMessage.createdAt,
            messages: [
                .init(id: "early", content: "Message early"),
                .init(id: "late", content: "Message late"),
            ]
        )

        continuation.yield(
            MessageSyncResponse(
                messages: [lateMessage, updatedEarlyMessage],
                deletedMessageIDs: []
            )
        )
        await store.receive(\.initialMessagesResponse) {
            $0.isLoadingMessages = false
        }
        await store.receive(\.messagesUpdated)
        try expectHumanPresentationCaches(
            store.state,
            turnID: "turn-1",
            startedAt: earlyMessage.createdAt,
            messages: [
                .init(id: "early", content: "Updated early message"),
                .init(id: "late", content: "Message late"),
            ]
        )
        continuation.yield(
            MessageSyncResponse(
                messages: [updatedLateMessage],
                deletedMessageIDs: []
            )
        )
        await store.receive(\.messagesUpdated)
        try expectHumanPresentationCaches(
            store.state,
            turnID: "turn-1",
            startedAt: earlyMessage.createdAt,
            messages: [
                .init(id: "early", content: "Updated early message"),
                .init(id: "late", content: "Updated late message"),
            ]
        )
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

            await store.send(.messagesUpdated([message]))
            try expectHumanPresentationCaches(
                store.state,
                turnID: "turn-1",
                startedAt: message.createdAt,
                messages: [.init(id: "human-1", content: "Hello")]
            )

            await store.send(.sessionStatusChanged(.working))
            expectNoDifference(
                try #require(store.state.rows).map(DisplayedRowProjection.init),
                [
                    .human(id: "human-1", content: "Hello"),
                    .turnInProgress(id: "turn-1", startedAt: message.createdAt),
                ]
            )

            await store.send(.sessionStatusChanged(.idle))
            try expectHumanPresentationCaches(
                store.state,
                turnID: "turn-1",
                startedAt: message.createdAt,
                messages: [.init(id: "human-1", content: "Hello")]
            )
        }
    }

    @Test("An empty sync acknowledgement preserves cached messages")
    func emptySyncAcknowledgement() async throws {
        let database = try appDatabase()
        let session = try makeSession()
        let message = try makeMessage(
            id: "cached",
            sessionID: session.id,
            createdAt: "2026-07-09 01:00:00"
        )
        try await database.write { db in
            try Message.insert { message }.execute(db)
        }
        let baselineChangeCount = try await database.write { $0.totalChangesCount }

        let messages = try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            try await Chat().reconcileMessages(
                MessageSyncResponse(messages: [], deletedMessageIDs: []),
                sessionID: session.id
            )
        }

        expectNoDifference(messages, [message])
        #expect(
            try await database.write { $0.totalChangesCount }
                == baselineChangeCount
        )
    }

    @Test("Message sync applies upserts and session-scoped deletions atomically")
    func messageSyncReconciliation() async throws {
        let database = try appDatabase()
        let session = try makeSession()
        let stale = try makeMessage(
            id: "stale",
            sessionID: session.id,
            createdAt: "2026-07-09 01:00:00"
        )
        let otherSessionMessage = try makeMessage(
            id: "other",
            sessionID: "session-2",
            createdAt: "2026-07-09 00:00:00"
        )
        var updated = try makeMessage(
            id: "updated",
            sessionID: session.id,
            createdAt: "2026-07-09 02:00:00"
        )
        updated.content = "Updated"
        try await database.write { db in
            try Message.insert { [stale, otherSessionMessage] }.execute(db)
        }

        let messages = try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            try await Chat().reconcileMessages(
                MessageSyncResponse(
                    messages: [updated],
                    deletedMessageIDs: [stale.id, otherSessionMessage.id]
                ),
                sessionID: session.id
            )
        }

        expectNoDifference(messages, [updated])
        let storedOtherMessage = try await database.read {
            try Message.find(otherSessionMessage.id).fetchOne($0)
        }
        expectNoDifference(storedOtherMessage, otherSessionMessage)
    }

    @Test("Message sync rejects rows from another session without mutating the cache")
    func messageSyncRejectsAnotherSession() async throws {
        let database = try appDatabase()
        let sessionID = "session-1"
        let cached = try makeMessage(
            id: "cached",
            sessionID: sessionID,
            createdAt: "2026-07-09 01:00:00"
        )
        let incoming = try makeMessage(
            id: "incoming",
            sessionID: "session-2",
            createdAt: "2026-07-09 02:00:00"
        )
        try await database.write { db in
            try Message.insert { cached }.execute(db)
        }

        await #expect(throws: MessageReconciliationError.self) {
            try await withDependencies {
                $0.defaultDatabase = database
            } operation: {
                try await Chat().reconcileMessages(
                    MessageSyncResponse(
                        messages: [incoming],
                        deletedMessageIDs: [cached.id]
                    ),
                    sessionID: sessionID
                )
            }
        }

        let storedMessages = try await database.read {
            try Message.order(by: \.id).fetchAll($0)
        }
        expectNoDifference(storedMessages, [cached])
    }

    @Test("An empty initial response replaces cached presentation and shows the empty state")
    func emptyInitialResponse() async throws {
        let session = try makeSession()
        let message: Message = .init(
            id: "cached",
            sessionID: session.id,
            role: .user,
            content: "Cached message",
            createdAt: Date(timeIntervalSince1970: 0),
            turnID: "turn-1"
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Message.upsert { message }.execute(db)
            }
        } operation: {
            let state = Chat.State(session: session)
            try await state.$messages.load()
            let messages = state.messages
            let store = TestStore(initialState: state) {
                Chat()
            }

            await store.send(.messagesUpdated(messages))
            expectNoDifference(store.state.messages, [message])
            #expect(store.state.isLoadingMessages)
            #expect(!store.state.shouldShowEmptyChat)

            await store.send(
                .initialMessagesResponse(
                    sessionID: session.id,
                    messages: []
                )
            ) {
                $0.isLoadingMessages = false
                $0.isMessageSnapshotEmpty = true
            }
            expectNoDifference(store.state.messages, [message])
            #expect(try #require(store.state.turns).isEmpty)
            #expect(try #require(store.state.rows).isEmpty)
            #expect(store.state.shouldShowEmptyChat)
        }
    }

    @Test("Protocol-only messages produce no turns but remain a nonempty snapshot")
    func protocolOnlyMessagesRemainNonempty() async throws {
        let session = try makeSession()
        let message: Message = .init(
            id: "system",
            sessionID: session.id,
            role: .assistant,
            content: #"{"type":"system","subtype":"status","status":"compacting"}"#,
            createdAt: Date(timeIntervalSince1970: 0),
            turnID: "turn-1"
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            }

            await store.send(
                .initialMessagesResponse(
                    sessionID: session.id,
                    messages: [message]
                )
            ) {
                $0.isLoadingMessages = false
            }

            #expect(!store.state.isMessageSnapshotEmpty)
            #expect(store.state.turns?.isEmpty == true)
            #expect(store.state.rows?.isEmpty == true)
            #expect(!store.state.shouldShowEmptyChat)
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
            await store.send(
                .initialMessagesResponse(
                    sessionID: session.id,
                    messages: []
                )
            ) {
                $0.confirmedMessagesAwaitingInitialSnapshot = []
                $0.isLoadingMessages = false
            }
            #expect(!store.state.shouldShowEmptyChat)
            try expectHumanPresentationCaches(
                store.state,
                turnID: "turn-1",
                startedAt: message.createdAt,
                messages: [.init(id: message.id, content: "Run the tests.")]
            )
        }
    }

    @Test("Fetched default model applies only before a compatible user selection")
    func defaultModel() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let session = Session.preview(model: .gpt5_5)
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            }

            await store.send(.defaultModelFetched(.gpt_5_6_sol)) {
                $0.selectedModel = .gpt_5_6_sol
            }
            await store.send(.binding(.set(\.selectedModel, .gpt_5_6_terra))) {
                $0.selectedModel = .gpt_5_6_terra
                $0.hasUserSelectedModel = true
            }
            await store.send(.defaultModelFetched(.gpt5_4))
            await store.send(.defaultModelFetched(.fable5))
        }
    }

    @Test("The model selected during creation is not replaced by the desktop default")
    func creationModel() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let session = Session.preview(model: .gpt_5_6_terra)
            let store = TestStore(
                initialState: Chat.State(
                    session: session,
                    selectedModel: .gpt_5_6_terra
                )
            ) {
                Chat()
            }

            #expect(store.state.hasUserSelectedModel)
            await store.send(.defaultModelFetched(.gpt_5_6_sol))
            #expect(store.state.selectedModel == .gpt_5_6_terra)
        }
    }

    @Test("An explicit selection wins after returning to the initial model")
    func explicitModelSelection() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let store = TestStore(
                initialState: Chat.State(session: .preview(model: .gpt5_5))
            ) {
                Chat()
            }

            await store.send(.binding(.set(\.selectedModel, .gpt_5_6_terra))) {
                $0.selectedModel = .gpt_5_6_terra
                $0.hasUserSelectedModel = true
            }
            await store.send(.binding(.set(\.selectedModel, .gpt5_5))) {
                $0.selectedModel = .gpt5_5
            }
            await store.send(.defaultModelFetched(.gpt_5_6_sol))
        }
    }

    @Test("Observed session models apply until the user selects a model")
    func sessionModel() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let store = TestStore(
                initialState: Chat.State(session: .preview(model: .gpt5_5))
            ) {
                Chat()
            }

            await store.send(.sessionModelChanged(.gpt_5_6_sol)) {
                $0.hasObservedSessionModelChange = true
                $0.selectedModel = .gpt_5_6_sol
            }
            await store.send(.defaultModelFetched(.gpt5_4))
            await store.send(.binding(.set(\.selectedModel, .gpt_5_6_terra))) {
                $0.selectedModel = .gpt_5_6_terra
                $0.hasUserSelectedModel = true
            }
            await store.send(.sessionModelChanged(.gpt5_4))
        }
    }

    @Test("Steering forwards the selected model and fast mode, then clears the draft")
    func messageSendSucceeds() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            @Dependency(\.defaultDatabase) var database

            let session = Session.preview(status: .working, isFastModeEnabled: true)
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
                $0.desktopClient.sendMessage = { workspaceID, sessionID, message, model, isFastModeEnabled in
                    #expect(workspaceID == session.workspaceID)
                    #expect(sessionID == session.id)
                    #expect(message == "Please run the tests.")
                    #expect(model == .gpt_5_6_terra)
                    #expect(isFastModeEnabled)
                    return sentMessage
                }
            }

            await store.send(.binding(.set(\.selectedModel, .gpt_5_6_terra))) {
                $0.selectedModel = .gpt_5_6_terra
                $0.hasUserSelectedModel = true
            }
            store.state.$messageDraft.withLock { $0 = "  Please run the tests.  " }
            await store.send(.sendButtonTapped) {
                $0.isMessageSendInFlight = true
                $0.scrollToBottomRequest = 1
            }
            await store.receive(\.messageConfirmed) {
                $0.confirmedMessagesAwaitingInitialSnapshot = [sentMessage]
            }
            await store.receive(\.sendMessageResponse) {
                $0.$messageDraft.withLock { $0 = "" }
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
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let session = Session.preview()
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            } withDependencies: {
                $0.desktopClient.sendMessage = { _, _, _, _, _ in nil }
            }

            store.state.$messageDraft.withLock { $0 = "Run the tests." }
            await store.send(.sendButtonTapped) {
                $0.isMessageSendInFlight = true
                $0.scrollToBottomRequest = 1
            }
            await store.receive(\.sendMessageResponse) {
                $0.$messageDraft.withLock { $0 = "" }
                $0.isMessageSendInFlight = false
            }
        }
    }

    @Test("A send response preserves a draft edited while the request was in flight")
    func editedDraftIsPreserved() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let session = Session.preview()
            let (responses, responseContinuation) = AsyncStream<Message?>.makeStream()
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            } withDependencies: {
                $0.desktopClient.sendMessage = { _, _, _, _, _ in
                    for await response in responses {
                        return response
                    }
                    throw TestError()
                }
            }

            store.state.$messageDraft.withLock { $0 = "Run the tests." }
            await store.send(.sendButtonTapped) {
                $0.isMessageSendInFlight = true
                $0.scrollToBottomRequest = 1
            }
            store.state.$messageDraft.withLock { $0 = "Only run unit tests." }

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
            $0.defaultFileStorage = .inMemory
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
                $0.desktopClient.sendMessage = { _, _, _, _, _ in responseMessage }
            }

            store.state.$messageDraft.withLock { $0 = "Run the tests." }
            await store.send(.sendButtonTapped) {
                $0.isMessageSendInFlight = true
                $0.scrollToBottomRequest = 1
            }
            await store.receive(\.messageConfirmed) {
                $0.confirmedMessagesAwaitingInitialSnapshot = [responseMessage]
            }
            await store.receive(\.sendMessageResponse) {
                $0.$messageDraft.withLock { $0 = "" }
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
            $0.defaultFileStorage = .inMemory
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
                $0.desktopClient.sendMessage = { _, _, _, _, _ in responseMessage }
            }

            store.state.$messageDraft.withLock { $0 = "Run the tests." }
            try database.close()

            await store.send(.sendButtonTapped) {
                $0.isMessageSendInFlight = true
                $0.scrollToBottomRequest = 1
            }
            await store.receive(\.messageConfirmed) {
                $0.confirmedMessagesAwaitingInitialSnapshot = [responseMessage]
            }
            await store.receive(\.sendMessageResponse) {
                $0.$messageDraft.withLock { $0 = "" }
                $0.isMessageSendInFlight = false
            }
            await store.finish()
        }
    }

    @Test("A send failure keeps the message draft")
    func messageSendFails() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let session = try makeSession()
            let state = Chat.State(session: session)
            state.$messageDraft.withLock { $0 = "Please try this again." }
            let store = TestStore(initialState: state) {
                Chat()
            } withDependencies: {
                $0.desktopClient.sendMessage = { _, _, _, _, _ in
                    throw TestError()
                }
            }

            await store.send(.sendButtonTapped) {
                $0.isMessageSendInFlight = true
                $0.scrollToBottomRequest = 1
            }
            await store.receive(\.sendMessageResponse) {
                $0.isMessageSendInFlight = false
            }
        }
    }

    @Test("Fast mode changes locally and is sent with the next message")
    func fastModeChangesLocally() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let session = try makeSession()
            let isRecordedFastModeEnabled = LockIsolated<Bool?>(nil)
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            } withDependencies: {
                $0.desktopClient.sendMessage = { workspaceID, sessionID, message, model, isFastModeEnabled in
                    #expect(workspaceID == session.workspaceID)
                    #expect(sessionID == session.id)
                    #expect(message == "Use the next setting.")
                    #expect(model == session.model)
                    isRecordedFastModeEnabled.withValue { $0 = isFastModeEnabled }
                    return nil
                }
            }

            await store.send(.fastModeButtonTapped) {
                $0.isFastModeEnabled = false
            }
            #expect(isRecordedFastModeEnabled.value == nil)

            store.state.$messageDraft.withLock { $0 = "Use the next setting." }
            await store.send(.sendButtonTapped) {
                $0.isMessageSendInFlight = true
                $0.scrollToBottomRequest = 1
            }
            await store.receive(\.sendMessageResponse) {
                $0.$messageDraft.withLock { $0 = "" }
                $0.isMessageSendInFlight = false
            }
            expectNoDifference(isRecordedFastModeEnabled.value, false)
        }
    }

    @Test("Fast mode follows the observed session setting")
    func fastModeFollowsObservedSession() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let session = try makeSession()
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            }

            await store.send(.sessionFastModeChanged(false)) {
                $0.isFastModeEnabled = false
            }
            await store.send(.sessionFastModeChanged(true)) {
                $0.isFastModeEnabled = true
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

    @Test("Cloud summary taps preserve the shared working status")
    func cloudTurnSummaryTappedPreservesWorkingStatus() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let completedTurn = Turn(
                id: "turn-1",
                startedAt: Date(timeIntervalSince1970: 1_000),
                rows: [
                    .humanMessageRow(.init(id: "human-1", content: "Inspect it")),
                    .assistantMessage(
                        .toolCall(
                            messageID: "tool-1",
                            toolCall: .readFile(
                                toolUseID: "tool-1",
                                filePath: "File.swift"
                            )
                        )
                    ),
                    .assistantMessage(
                        .text(
                            messageID: "final-1",
                            content: .init("Inspected"),
                            isMostRecentTextInTurn: true
                        )
                    ),
                ]
            )
            let activeTurn = Turn(
                id: "turn-2",
                startedAt: Date(timeIntervalSince1970: 2_000),
                rows: [
                    .humanMessageRow(.init(id: "human-2", content: "Fix it")),
                ]
            )
            let summaryID = "turn-1:human-1"
            var state = Chat.State(
                cloudSession: cloudSession(),
                workspaceID: "workspace-1"
            )
            state.cloudSessionStatus = .working
            state.turns = [completedTurn, activeTurn]
            state.updateRows(sessionStatus: state.sessionStatus)
            let store = TestStore(initialState: state) {
                Chat()
            }

            await store.send(.turnSummaryTapped(summaryID)) {
                $0.expandedSummaryIDs = [summaryID]
                $0.rows = [completedTurn, activeTurn].flattenedChatRows(
                    activeTurnID: activeTurn.id,
                    expandedSummaryIDs: [summaryID]
                )
            }
            let rows = try #require(store.state.rows)
            #expect(
                rows.contains {
                    if case .turnInProgress = $0.content {
                        true
                    } else {
                        false
                    }
                }
            )
        }
    }

    @Test("Real cloud transcript events use the canonical chat rows")
    func cloudTranscriptUsesCanonicalRows() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let transcript = try cloudTranscriptMessages()
            let canonicalMessages = transcript.flatMap(\.chatMessages)
            let status = CloudSessionStatusResponse(
                workspaceID: "workspace-1",
                sessionID: "session-1",
                status: .working,
                updatedAt: try #require(transcript.last?.receivedAt)
            )
            let clock = TestClock()
            let store = TestStore(
                initialState: Chat.State(
                    cloudSession: cloudSession(),
                    workspaceID: "workspace-1"
                )
            ) {
                Chat()
            } withDependencies: {
                $0.continuousClock = clock
            }

            await store.send(
                .cloudSnapshotResponse(
                    isInitial: true,
                    .success(
                        Chat.CloudSnapshot(
                            messages: transcript,
                            status: status
                        )
                    )
                )
            ) {
                $0.cloudMessages = canonicalMessages
                $0.cloudSessionStatus = .working
                $0.isLoadingMessages = false
                $0.lastCloudMessageID = "agent-text"
                $0.turns = Turn.parse(messages: canonicalMessages)
                $0.updateRows(sessionStatus: .working)
            }

            expectNoDifference(
                canonicalMessages.map(\.id),
                [
                    "user-1",
                    "agent-command-start",
                    "agent-command-complete",
                    "agent-text",
                ]
            )
            expectNoDifference(
                try #require(store.state.rows).map(DisplayedRowProjection.init),
                [
                    .human(id: "user-1", content: "Run the tests."),
                    .assistant(id: "assistant:agent-command-start"),
                    .assistant(id: "assistant:agent-text:chunk:0"),
                    .turnInProgress(
                        id: "turn-1",
                        startedAt: canonicalMessages[0].createdAt
                    ),
                ]
            )

            await store.send(.viewDisappeared)
            await store.finish()
        }
    }

    @Test("Cloud send uses the shared draft and send actions")
    func cloudMessageSendSucceeds() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let clock = TestClock()
            let request = LockIsolated<(String, String, String)?>(nil)
            let fixedUUID = UUID(42)
            let store = TestStore(
                initialState: Chat.State(
                    cloudSession: cloudSession(),
                    workspaceID: "workspace-1"
                )
            ) {
                Chat()
            } withDependencies: {
                $0.continuousClock = clock
                $0.uuid = .constant(fixedUUID)
                $0.cloudAPIClient.sendMessage = { sessionID, messageID, message in
                    request.setValue((sessionID, messageID, message))
                    return CloudSendMessageResponse(
                        messageID: "server-message",
                        state: .queued
                    )
                }
            }

            store.state.$messageDraft.withLock {
                $0 = "  Please run the tests.  "
            }
            await store.send(.sendButtonTapped) {
                $0.isMessageSendInFlight = true
                $0.scrollToBottomRequest = 1
            }
            await store.receive(\.sendMessageResponse) {
                $0.$messageDraft.withLock { $0 = "" }
                $0.cloudSessionStatus = .working
                $0.isMessageSendInFlight = false
            }
            expectNoDifference(
                request.value.map {
                    [$0.0, $0.1, $0.2]
                },
                [
                    "session-1",
                    fixedUUID.uuidString.lowercased(),
                    "Please run the tests.",
                ]
            )

            await store.send(.viewDisappeared)
            await store.finish()
        }
    }

    @Test("Cloud task advances the transcript cursor through the shared chat")
    func cloudTaskPollsIncrementally() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let transcript = try cloudTranscriptMessages()
            let canonicalMessages = transcript.flatMap(\.chatMessages)
            let clock = TestClock()
            let requestedCursors = LockIsolated<[String?]>([])
            let status = CloudSessionStatusResponse(
                workspaceID: "workspace-1",
                sessionID: "session-1",
                status: .working,
                updatedAt: try #require(transcript.last?.receivedAt)
            )
            let store = TestStore(
                initialState: Chat.State(
                    cloudSession: cloudSession(),
                    workspaceID: "workspace-1"
                )
            ) {
                Chat()
            } withDependencies: {
                $0.continuousClock = clock
                $0.cloudAPIClient.messages = { _, _, _, after in
                    requestedCursors.withValue { $0.append(after) }
                    return CloudPage(
                        data: after == nil ? transcript : [],
                        offset: 0,
                        hasMore: false
                    )
                }
                $0.cloudAPIClient.sessionStatus = { _ in status }
            }

            await store.send(.task)
            await store.receive(\.cloudSnapshotResponse) {
                $0.cloudMessages = canonicalMessages
                $0.cloudSessionStatus = .working
                $0.isLoadingMessages = false
                $0.lastCloudMessageID = "agent-text"
                $0.turns = Turn.parse(messages: canonicalMessages)
                $0.updateRows(sessionStatus: .working)
            }

            await clock.advance(by: .seconds(3))
            await store.receive(\.cloudPoll)
            await store.receive(\.cloudSnapshotResponse)
            expectNoDifference(
                requestedCursors.value,
                [nil, "agent-text"]
            )

            await store.send(.viewDisappeared)
            await store.finish()
        }
    }

    @Test("Cloud stop uses the shared stop action")
    func cloudStopSucceeds() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let cancelledSessionID = LockIsolated<String?>(nil)
            var state = Chat.State(
                cloudSession: cloudSession(),
                workspaceID: "workspace-1"
            )
            state.cloudSessionStatus = .working
            let store = TestStore(initialState: state) {
                Chat()
            } withDependencies: {
                $0.cloudAPIClient.cancelSession = { sessionID in
                    cancelledSessionID.setValue(sessionID)
                    return CloudCancelResponse(
                        workspaceID: "workspace-1",
                        sessionID: sessionID,
                        status: .idle,
                        canceledQueuedMessages: 0
                    )
                }
            }

            await store.send(.stopButtonTapped) {
                $0.isStopInFlight = true
            }
            await store.receive(\.stopSessionResponse) {
                $0.cloudSessionStatus = .idle
                $0.isStopInFlight = false
            }

            #expect(cancelledSessionID.value == "session-1")
        }
    }
}

@MainActor
private func firstTextInputResponder(in view: UIView) -> (UIView & UIKeyInput)? {
    if view.isFirstResponder, let textInput = view as? UIView & UIKeyInput {
        return textInput
    }
    for subview in view.subviews {
        if let responder = firstTextInputResponder(in: subview) {
            return responder
        }
    }
    return nil
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
              "model": "gpt-5.5",
              "fast_mode": true,
              "unread_count": 0,
              "freshly_compacted": 0,
              "context_token_count": 0
            }
            """.utf8
        )
    )
}

private func cloudSession() -> CloudSession {
    CloudSession(
        id: "session-1",
        deepLink: CloudAPIClient.productionBaseURL,
        name: "Cloud chat",
        model: Session.Model.gpt_5_6_sol.rawValue
    )
}

private func cloudTranscriptMessages() throws -> [CloudTranscriptMessage] {
    try JSONDecoder.cloud.decode(
        CloudPage<CloudTranscriptMessage>.self,
        from: Data(
            #"""
            {
              "data": [
                {
                  "id": "user-1",
                  "sessionId": "session-1",
                  "sessionIndex": 1,
                  "type": "userMessage",
                  "content": {
                    "type": "userMessage",
                    "id": "user-item-1",
                    "message": "Run the tests.",
                    "state": "sent",
                    "turnId": "turn-1",
                    "config": {"model": "gpt-5.6-sol"},
                    "senderId": "user-1"
                  },
                  "receivedAt": "2026-07-24 15:24:17.562275+00"
                },
                {
                  "id": "agent-command-start",
                  "sessionId": "session-1",
                  "sessionIndex": 2,
                  "type": "agent",
                  "content": {
                    "type": "agent",
                    "eventId": "event-1",
                    "turnId": "turn-1",
                    "userMessageId": "user-item-1",
                    "rawPayload": {
                      "thread_id": "thread-1",
                      "event": {
                        "type": "item.started",
                        "item": {
                          "id": "command-1",
                          "type": "commandExecution",
                          "command": "mise -C ios run test",
                          "status": "inProgress"
                        }
                      }
                    }
                  },
                  "receivedAt": "2026-07-24 15:24:18.000001+00"
                },
                {
                  "id": "agent-command-complete",
                  "sessionId": "session-1",
                  "sessionIndex": 3,
                  "type": "agent",
                  "content": {
                    "type": "agent",
                    "eventId": "event-2",
                    "turnId": "turn-1",
                    "userMessageId": "user-item-1",
                    "rawPayload": {
                      "thread_id": "thread-1",
                      "event": {
                        "type": "item.completed",
                        "item": {
                          "id": "command-1",
                          "type": "commandExecution",
                          "command": "mise -C ios run test",
                          "aggregatedOutput": "All tests passed.",
                          "exitCode": 0,
                          "status": "completed"
                        }
                      }
                    }
                  },
                  "receivedAt": "2026-07-24 15:24:19.000001+00"
                },
                {
                  "id": "agent-text",
                  "sessionId": "session-1",
                  "sessionIndex": 4,
                  "type": "agent",
                  "content": {
                    "type": "agent",
                    "eventId": "event-3",
                    "turnId": "turn-1",
                    "userMessageId": "user-item-1",
                    "rawPayload": {
                      "thread_id": "thread-1",
                      "event": {
                        "type": "item.completed",
                        "item": {
                          "id": "assistant-item-1",
                          "type": "agentMessage",
                          "text": "All tests passed."
                        }
                      }
                    }
                  },
                  "receivedAt": "2026-07-24 15:24:20.000001+00"
                }
              ],
              "offset": 0,
              "hasMore": false
            }
            """#.utf8
        )
    ).data
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
    case turnFooter(id: String)

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
        case .turnFooter(let footer):
            .turnFooter(id: footer.id)
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
