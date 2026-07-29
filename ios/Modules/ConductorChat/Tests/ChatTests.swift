//
//  ChatTests.swift
//  ConductorChatTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import ComposableArchitecture
import ConductorCloud
import ConductorMobileData
import CustomDump
import Foundation
import SharedConductorData
import Sharing
import SQLiteData
import SwiftUI
@testable import ConductorChat
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
                try? await clock.sleep(for: .milliseconds(10))
            }

            let responder = try #require(firstTextInputResponder(in: hostingController.view))
            responder.insertText("Test message")

            while store.state.messageDraft != "Test message", clock.now < deadline {
                try? await clock.sleep(for: .milliseconds(10))
            }
            #expect(store.state.messageDraft == "Test message")
        }
    }

    @Test("A constrained chat keeps one complete queued row above a growing composer")
    func constrainedQueueLayout() async throws {
        let session = try makeSession(status: "working")
        let queuedMessages = (1...8).map { index in
            Message(
                id: "queued-\(index)",
                sessionID: session.id,
                role: .user,
                content: "Queued message \(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                queueOrder: index
            )
        }

        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Message.insert { queuedMessages }.execute(database)
            }
        } operation: {
            @Shared(.desktopConnectionStatus) var connectionStatus
            $connectionStatus.withLock { $0 = .disconnected }

            var state = Chat.State(session: session)
            try await state.queuedMessages.$messages.load()
            state.queuedMessages.isExpanded = true
            state.isLoadingMessages = false
            state.isMessageSnapshotEmpty = true
            state.$messageDraft.withLock {
                $0 = (1...8)
                    .map { "Composer line \($0)" }
                    .joined(separator: "\n")
            }
            let store = Store(initialState: state) {
                Chat()
            } withDependencies: {
                $0.desktopClient.fetchModelSettings = {
                    .init(
                        defaultModel: session.model,
                        defaultReasoningEffort: session.model.defaultReasoningEffort,
                        isFastModeEnabled: false
                    )
                }
                $0.chatSyncClient.observeSelected = { _ in
                    AsyncStream { _ in }
                }
            }
            let queuedRowFrame = LockIsolated<CGRect?>(nil)
            let hostingController = UIHostingController(
                rootView: ChatView(
                    store: store,
                    directoryName: "repo",
                    firstQueuedRowFrameChanged: { frame in
                        queuedRowFrame.withValue { $0 = frame }
                    }
                )
            )
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
            window.rootViewController = hostingController
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(1))
            while queuedRowFrame.value == nil, clock.now < deadline {
                hostingController.view.layoutIfNeeded()
                try? await clock.sleep(for: .milliseconds(10))
            }

            let rowFrame = try #require(queuedRowFrame.value)

            #expect(rowFrame.height >= 43)
            #expect(rowFrame.minY >= window.frame.minY)
            #expect(rowFrame.maxY <= window.frame.maxY)
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

    @Test("A complete empty Cloud cache clears the loader before observation")
    func completeEmptyCloudCacheClearsLoader() async throws {
        let database = try appDatabase()
        let sessionID = CloudCanonicalID.session(
            accountID: "account",
            remoteSessionID: "remote-session"
        )
        let session = Session.preview(id: sessionID)
        try await database.write { db in
            try Session.insert { session }.execute(db)
            try CloudSessionMetadata
                .insert {
                    CloudSessionMetadata(
                        canonicalSessionID: sessionID,
                        cloudSessionID: "remote-session",
                        workspaceID: session.workspaceID,
                        accountID: "account",
                        listOrder: 0,
                        refreshGeneration: "generation",
                        transcriptCursor: nil,
                        hasCompleteTranscript: true,
                        transcriptProjectionVersion: CloudTranscriptAdapter
                            .projectionVersion
                    )
                }
                .execute(db)
        }

        await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            let store = TestStore(
                initialState: Chat.State(
                    session: session,
                    isCloudHosted: true
                )
            ) {
                Chat()
            } withDependencies: {
                $0.defaultDatabase = database
                $0.desktopClient.fetchModelSettings = {
                    DesktopClient.ModelSettings(
                        defaultModel: session.model,
                        defaultReasoningEffort: session.model.defaultReasoningEffort,
                        isFastModeEnabled: false
                    )
                }
                $0.chatSyncClient.observeSelected = { selectedSessionID in
                    #expect(selectedSessionID == session.id)
                    return AsyncStream { continuation in
                        continuation.yield(.ready)
                    }
                }
            }
            store.exhaustivity = .off

            let task = await store.send(.task)
            await store.receive(\.initialMessagesResponse) {
                $0.isMessageSnapshotEmpty = true
                $0.isLoadingMessages = false
            }
            await task.cancel()
        }
    }

    @Test("A same-account credential revision restarts transcript observation")
    func credentialRevisionRestartsTranscriptObservation() async throws {
        let database = try appDatabase()
        let sessionID = CloudCanonicalID.session(
            accountID: "account",
            remoteSessionID: "remote-session"
        )
        let session = Session.preview(id: sessionID)
        try await database.write { db in
            try Session.insert { session }.execute(db)
            try CloudSessionMetadata.insert {
                CloudSessionMetadata(
                    canonicalSessionID: sessionID,
                    cloudSessionID: "remote-session",
                    workspaceID: session.workspaceID,
                    accountID: "account",
                    listOrder: 0,
                    refreshGeneration: "generation"
                )
            }
            .execute(db)
        }

        await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            @Shared(.cloudConfiguration) var cloudConfiguration
            $cloudConfiguration.withLock {
                $0 = CloudConfiguration(
                    accountID: "account",
                    credentialRevision: 1
                )
            }
            let selectionCount = LockIsolated(0)
            let store = TestStore(
                initialState: Chat.State(
                    session: session,
                    isCloudHosted: true
                )
            ) {
                Chat()
            } withDependencies: {
                $0.defaultDatabase = database
                $0.chatSyncClient.observeSelected = { _ in
                    selectionCount.withValue { $0 += 1 }
                    return AsyncStream { _ in }
                }
                $0.desktopClient.fetchModelSettings = {
                    DesktopClient.ModelSettings(
                        defaultModel: session.model,
                        defaultReasoningEffort:
                            session.model.defaultReasoningEffort,
                        isFastModeEnabled: false
                    )
                }
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            let task = await store.send(.task)
            await waitUntil { selectionCount.value >= 1 }
            $cloudConfiguration.withLock {
                $0 = CloudConfiguration(
                    accountID: "account",
                    credentialRevision: 2
                )
            }
            await store.receive(\.cloudConfigurationChanged)
            await waitUntil { selectionCount.value >= 2 }
            #expect(selectionCount.value == 2)

            await task.cancel()
        }
    }

    @Test("A stale Cloud projection keeps loading until complete recovery commits")
    func staleCloudProjectionRequiresRecovery() async throws {
        let database = try appDatabase()
        let sessionID = CloudCanonicalID.session(
            accountID: "account",
            remoteSessionID: "remote-session"
        )
        let session = Session.preview(id: sessionID)
        try await database.write { db in
            try Session.insert { session }.execute(db)
            try CloudSessionMetadata
                .insert {
                    CloudSessionMetadata(
                        canonicalSessionID: sessionID,
                        cloudSessionID: "remote-session",
                        workspaceID: session.workspaceID,
                        accountID: "account",
                        listOrder: 0,
                        refreshGeneration: "generation",
                        transcriptCursor: "stale",
                        hasCompleteTranscript: true,
                        transcriptProjectionVersion: 0
                    )
                }
                .execute(db)
        }

        try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            let store = TestStore(
                initialState: Chat.State(
                    session: session,
                    isCloudHosted: true
                )
            ) {
                Chat()
            } withDependencies: {
                $0.defaultDatabase = database
                $0.desktopClient.fetchModelSettings = {
                    DesktopClient.ModelSettings(
                        defaultModel: session.model,
                        defaultReasoningEffort: session.model.defaultReasoningEffort,
                        isFastModeEnabled: false
                    )
                }
                $0.chatSyncClient.observeSelected = { selectedSessionID in
                    #expect(selectedSessionID == session.id)
                    return AsyncStream { continuation in
                        Task {
                            try await database.write { db in
                                _ = try CloudChatPersistence.persist(
                                    CloudTranscriptUpdate(
                                        accountID: "account",
                                        sessionID: "remote-session",
                                        messages: [],
                                        kind: .complete,
                                        rawCursor: nil
                                    ),
                                    in: db
                                )
                            }
                            continuation.yield(.ready)
                        }
                    }
                }
            }
            store.exhaustivity = .off

            let task = await store.send(.task)
            #expect(store.state.isLoadingMessages)
            await store.receive(\.initialMessagesResponse) {
                $0.isMessageSnapshotEmpty = true
                $0.isLoadingMessages = false
            }
            await task.cancel()

            let cache = try await database.read { db in
                try CloudChatPersistence.cachedTranscript(
                    for: sessionID,
                    in: db
                )
            }
            #expect(cache.checkpoint?.rawCursor == nil)
        }
    }

    @Test("Cloud ownership failure terminates observation at the committed checkpoint")
    func cloudOwnershipFailureTerminatesObservation() async throws {
        let database = try appDatabase()
        let sessionID = CloudCanonicalID.session(
            accountID: "account",
            remoteSessionID: "remote-session"
        )
        let session = Session.preview(id: sessionID)
        try await database.write { db in
            try Session.insert { session }.execute(db)
            try CloudSessionMetadata
                .insert {
                    CloudSessionMetadata(
                        canonicalSessionID: sessionID,
                        cloudSessionID: "remote-session",
                        workspaceID: session.workspaceID,
                        accountID: "account",
                        listOrder: 0,
                        refreshGeneration: "generation",
                        transcriptCursor: "committed",
                        hasCompleteTranscript: true,
                        transcriptProjectionVersion: CloudTranscriptAdapter
                            .projectionVersion
                    )
                }
                .execute(db)
        }
        let (stream, continuation) = AsyncStream<ChatSyncEvent>
            .makeStream()

        try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            let store = TestStore(
                initialState: Chat.State(
                    session: session,
                    isCloudHosted: true
                )
            ) {
                Chat()
            } withDependencies: {
                $0.defaultDatabase = database
                $0.desktopClient.fetchModelSettings = {
                    DesktopClient.ModelSettings(
                        defaultModel: session.model,
                        defaultReasoningEffort: session.model.defaultReasoningEffort,
                        isFastModeEnabled: false
                    )
                }
                $0.chatSyncClient.observeSelected = { _ in stream }
            }
            store.exhaustivity = .off

            let task = await store.send(.task)
            continuation.yield(.ready)
            await store.receive(\.initialMessagesResponse)
            continuation.yield(.failure(CloudChatPersistenceError.transcriptOwnershipMismatch))
            await store.receive(\.loadMessagesFailed)
            try? await ContinuousClock().sleep(for: .milliseconds(50))

            let cache = try await database.read { db in
                try CloudChatPersistence.cachedTranscript(
                    for: sessionID,
                    in: db
                )
            }
            #expect(cache.checkpoint?.rawCursor == "committed")
            await task.cancel()
        }
    }

    @Test("Initial message database failures clear loading")
    func initialMessageDatabaseFailureClearsLoading() async throws {
        let database = try appDatabase()
        let session = try makeSession()
        let (stream, continuation) = AsyncStream<ChatSyncEvent>.makeStream()

        try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            let store = TestStore(
                initialState: Chat.State(session: session)
            ) {
                Chat()
            } withDependencies: {
                $0.defaultDatabase = database
                $0.desktopClient.fetchModelSettings = {
                    DesktopClient.ModelSettings(
                        defaultModel: session.model,
                        defaultReasoningEffort: session.model.defaultReasoningEffort,
                        isFastModeEnabled: false
                    )
                }
                $0.chatSyncClient.observeSelected = { _ in stream }
            }
            store.exhaustivity = .off

            let task = await store.send(.task)
            try await database.write { database in
                try #sql("DROP TABLE \"session_messages\"")
                    .execute(database)
            }
            continuation.yield(.ready)
            await store.receive(\.loadMessagesFailed) {
                $0.isLoadingMessages = false
            }

            await task.cancel()
            continuation.finish()
        }
    }

    @Test("Cancellation load failures do not dismiss loading")
    func cancellationLoadFailureDoesNotDismissLoading() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let session = try makeSession()
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            }

            await store.send(
                .loadMessagesFailed(
                    sessionID: session.id,
                    error: CancellationError()
                )
            )
            #expect(store.state.isLoadingMessages)
        }
    }

    @Test("The scroll-down button requests an animated bottom placement")
    func scrollDownButtonTapped() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let session = try makeSession()
            let store = TestStore(
                initialState: Chat.State(session: session)
            ) {
                Chat()
            }

            await store.send(.scrollDownButtonTapped) {
                $0.animatedScrollToBottomRequest = 1
                $0.scrollToBottomRequest = 1
            }
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

            var changedContextLimits = original
            changedContextLimits.reportedContextWindowTokenLimits[.gpt5_5] = 1_000_000
            #expect(original != changedContextLimits)

            var finishedLoading = original
            finishedLoading.isLoadingMessages = false
            #expect(original != finishedLoading)

            var emptySnapshot = original
            emptySnapshot.isMessageSnapshotEmpty = true
            #expect(original != emptySnapshot)

            emptySnapshot.isLoadingMessages = false
            #expect(emptySnapshot.allowsAgentSwitching)
            emptySnapshot.optimisticMessages = [
                .init(
                    id: UUID(),
                    workspaceID: emptySnapshot.session.workspaceID,
                    sessionID: emptySnapshot.sessionID,
                    content: "Sending",
                    model: emptySnapshot.selectedModel,
                    isFastModeEnabled: emptySnapshot.isFastModeEnabled,
                    mode: .sent,
                    reasoningEffort: emptySnapshot.selectedReasoningEffort,
                    status: .sending,
                    previousTurnID: nil
                ),
            ]
            #expect(!emptySnapshot.allowsAgentSwitching)
            emptySnapshot.optimisticMessages[0].status = .rejected
            #expect(emptySnapshot.allowsAgentSwitching)
        }
    }

    @Test("Context usage prefers reports and follows the selected model")
    func contextWindowUsageSelection() throws {
        try withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            var state = Chat.State(
                session: .preview(
                    agentType: .codex,
                    model: .gpt5_5,
                    contextTokenCount: 136_000
                )
            )

            expectNoDifference(
                state.contextWindowUsage,
                ContextWindowUsage(usedTokens: 136_000, tokenLimit: 272_000)
            )

            state.reportedContextWindowTokenLimits[.gpt5_5] = 400_000
            expectNoDifference(
                state.contextWindowUsage,
                ContextWindowUsage(usedTokens: 136_000, tokenLimit: 400_000)
            )

            state.selectedModel = .sonnet_4_6
            expectNoDifference(
                state.contextWindowUsage,
                ContextWindowUsage(usedTokens: 136_000, tokenLimit: 200_000)
            )

            state.selectedModel = Session.Model(rawValue: "future-model")
            #expect(state.contextWindowUsage == nil)
        }
    }

    @Test("Context usage clamps invalid and over-limit values")
    func contextWindowUsageMath() {
        let empty = ContextWindowUsage(usedTokens: -1, tokenLimit: 272_000)
        #expect(empty.usedTokens == 0)
        #expect(empty.fraction == 0)
        #expect(empty.percentage == 0)

        let partial = ContextWindowUsage(usedTokens: 136_000, tokenLimit: 272_000)
        #expect(partial.fraction == 0.5)
        #expect(partial.percentage == 50)

        let full = ContextWindowUsage(usedTokens: 400_000, tokenLimit: 272_000)
        #expect(full.fraction == 1)
        #expect(full.percentage == 100)

        let invalidLimit = ContextWindowUsage(usedTokens: 10, tokenLimit: 0)
        #expect(invalidLimit.fraction == 0)
        #expect(invalidLimit.percentage == 0)
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

    @Test("Messages are scoped to the session and ordered by actual send time")
    func messagesAreScopedAndOrdered() async throws {
        var delayedMessage = try makeMessage(
            id: "early",
            sessionID: "session-1",
            createdAt: "2026-07-09 01:00:00"
        )
        delayedMessage.sentAt = Date(timeIntervalSince1970: 1_783_566_000)
        var priorAssistantMessage = try makeMessage(
            id: "late",
            sessionID: "session-1",
            createdAt: "2026-07-09 02:00:00"
        )
        priorAssistantMessage.sentAt = Date(timeIntervalSince1970: 1_783_562_400)
        let otherMessage = try makeMessage(
            id: "other",
            sessionID: "session-2",
            createdAt: "2026-07-09 00:00:00"
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Message.upsert { priorAssistantMessage }.execute(db)
                try Message.upsert { otherMessage }.execute(db)
                try Message.upsert { delayedMessage }.execute(db)
            }
        } operation: {
            let state = Chat.State(session: try makeSession())
            try await state.$messages.load()

            expectNoDifference(
                state.messages,
                [priorAssistantMessage, delayedMessage]
            )
        }
    }

    @Test("Task observes selected readiness and cancels")
    func task() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let (stream, continuation) = AsyncStream<ChatSyncEvent>
                .makeStream()
            let session = try makeSession()
            let didCancelSelection = LockIsolated(false)
            continuation.onTermination = { termination in
                guard case .cancelled = termination else {
                    return
                }

                didCancelSelection.setValue(true)
            }
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            } withDependencies: {
                $0.desktopClient.fetchModelSettings = { throw CancellationError() }
                $0.chatSyncClient.observeSelected = { selectedSessionID in
                    #expect(selectedSessionID == session.id)
                    return stream
                }
            }

            let task = await store.send(.task)

            await store.receive(\.messagesUpdated) {
                $0.isMessageSnapshotEmpty = true
            }
            #expect(try #require(store.state.turns).isEmpty)
            #expect(try #require(store.state.rows).isEmpty)

            continuation.yield(.ready)
            await store.receive(\.initialMessagesResponse) {
                $0.isLoadingMessages = false
            }

            await task.cancel()
            await waitUntil { didCancelSelection.value }
            #expect(didCancelSelection.value)
        }
    }

    @Test("Task renders persisted message snapshots, changes, and deletions")
    func taskIngestsMessageBatches() async throws {
        let database = try appDatabase()
        let testID = UUID().uuidString
        let session = try makeSession(id: "session-\(testID)")
        var mutableEarlyMessage = try makeMessage(
            id: "early-\(testID)",
            sessionID: session.id,
            createdAt: "2026-07-09 01:00:00"
        )
        mutableEarlyMessage.role = .user
        mutableEarlyMessage.content = "Message early"
        mutableEarlyMessage.turnID = "turn-1"
        let earlyMessage = mutableEarlyMessage

        var mutableLateMessage = try makeMessage(
            id: "late-\(testID)",
            sessionID: session.id,
            createdAt: "2026-07-09 02:00:00"
        )
        mutableLateMessage.role = .user
        mutableLateMessage.content = "Message late"
        mutableLateMessage.turnID = "turn-1"
        let lateMessage = mutableLateMessage

        var mutableUpdatedEarlyMessage = earlyMessage
        mutableUpdatedEarlyMessage.content = "Updated early message"
        let updatedEarlyMessage = mutableUpdatedEarlyMessage
        var mutableUpdatedLateMessage = lateMessage
        mutableUpdatedLateMessage.content = "Updated late message"
        let updatedLateMessage = mutableUpdatedLateMessage

        try await database.write { db in
            try Message.upsert { [earlyMessage, lateMessage] }.execute(db)
        }
        let (stream, continuation) = AsyncStream<ChatSyncEvent>
            .makeStream()
        let store = Store(initialState: Chat.State(session: session)) {
            Chat()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.desktopClient.fetchModelSettings = { throw CancellationError() }
            $0.chatSyncClient.observeSelected = { selectedSessionID in
                #expect(selectedSessionID == session.id)
                return stream
            }
        }

        let task = store.send(.task)
        await waitUntil {
            humanMessageContent(in: store.state, id: lateMessage.id)
                == lateMessage.content
        }
        try expectHumanPresentationCaches(
            store.state,
            turnID: "turn-1",
            startedAt: earlyMessage.createdAt,
            messages: [
                .init(id: earlyMessage.id, content: "Message early"),
                .init(id: lateMessage.id, content: "Message late"),
            ]
        )

        try await database.write { db in
            try Message.find(earlyMessage.id).delete().execute(db)
            try Message.upsert { updatedEarlyMessage }.execute(db)
        }
        continuation.yield(.ready)
        await waitUntil { !store.state.isLoadingMessages }
        await waitUntil {
            humanMessageContent(in: store.state, id: earlyMessage.id)
                == updatedEarlyMessage.content
        }
        #expect(!store.state.isLoadingMessages)
        try expectHumanPresentationCaches(
            store.state,
            turnID: "turn-1",
            startedAt: earlyMessage.createdAt,
            messages: [
                .init(id: earlyMessage.id, content: "Updated early message"),
                .init(id: lateMessage.id, content: "Message late"),
            ]
        )
        try await database.write { db in
            try Message.upsert { updatedLateMessage }.execute(db)
        }
        await waitUntil {
            humanMessageContent(in: store.state, id: lateMessage.id)
                == updatedLateMessage.content
        }
        try expectHumanPresentationCaches(
            store.state,
            turnID: "turn-1",
            startedAt: earlyMessage.createdAt,
            messages: [
                .init(id: earlyMessage.id, content: "Updated early message"),
                .init(id: lateMessage.id, content: "Updated late message"),
            ]
        )
        let storedMessages = try await database.read { db in
            try Message
                .where { $0.sessionID.eq(session.id) }
                .order { ($0.createdAt, $0.id) }
                .fetchAll(db)
        }
        expectNoDifference(storedMessages, [updatedEarlyMessage, updatedLateMessage])

        task.cancel()
        continuation.finish()
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
                $0.isMessageSnapshotEmpty = false
                $0.turns = Turn.parse(messages: [message])
                $0.initializeIdleBaseline()
                $0.updateRows()
            }
            try expectHumanPresentationCaches(
                store.state,
                turnID: "turn-1",
                startedAt: message.createdAt,
                messages: [.init(id: "human-1", content: "Hello")]
            )

            await store.send(.sessionStatusChanged(.working)) {
                $0.sessionStatusChanged(.working)
            }
            expectNoDifference(
                try #require(store.state.rows).map(DisplayedRowProjection.init),
                [
                    .human(id: "human-1", content: "Hello"),
                    .turnInProgress(
                        id: "\(session.id):pending",
                        startedAt: try #require(session.updatedDate)
                    ),
                ]
            )

            let nextMessage = Message(
                id: "human-2",
                sessionID: session.id,
                role: .user,
                content: "Next",
                createdAt: message.createdAt.addingTimeInterval(1),
                turnID: "turn-2"
            )
            await store.send(.messagesUpdated([message, nextMessage]))
            expectNoDifference(
                try #require(store.state.rows).map(DisplayedRowProjection.init),
                [
                    .human(id: "human-1", content: "Hello"),
                    .human(id: "human-2", content: "Next"),
                    .turnInProgress(
                        id: "turn-2",
                        startedAt: nextMessage.createdAt
                    ),
                ]
            )

            await store.send(.sessionStatusChanged(.idle)) {
                $0.sessionStatusChanged(.idle)
            }
            expectNoDifference(
                try #require(store.state.rows).map(DisplayedRowProjection.init),
                [
                    .human(id: "human-1", content: "Hello"),
                    .human(id: "human-2", content: "Next"),
                ]
            )
        }
    }

    @Test("An empty initial response replaces cached presentation and shows the empty state")
    func emptyInitialResponse() async throws {
        let database = try appDatabase()
        let session = try makeSession()
        let message: Message = .init(
            id: "cached",
            sessionID: session.id,
            role: .user,
            content: "Cached message",
            createdAt: Date(timeIntervalSince1970: 0),
            turnID: "turn-1"
        )
        let (stream, continuation) = AsyncStream<ChatSyncEvent>
            .makeStream()
        try await database.write { db in
            try Message.upsert { message }.execute(db)
        }

        try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            let state = Chat.State(session: session)
            try await state.$messages.load()
            let messages = state.messages
            let store = TestStore(initialState: state) {
                Chat()
            } withDependencies: {
                $0.defaultDatabase = database
                $0.desktopClient.fetchModelSettings = { throw CancellationError() }
                $0.chatSyncClient.observeSelected = { _ in stream }
            }

            await store.send(.messagesUpdated(messages)) {
                $0.isMessageSnapshotEmpty = false
                $0.turns = Turn.parse(messages: messages)
                $0.initializeIdleBaseline()
                $0.updateRows()
            }
            expectNoDifference(store.state.messages, [message])
            #expect(store.state.isLoadingMessages)
            #expect(!store.state.shouldShowEmptyChat)

            let task = await store.send(.task)
            store.exhaustivity = .off
            try await database.write { db in
                try Message.find(message.id).delete().execute(db)
            }
            continuation.yield(.ready)
            await store.receive(\.initialMessagesResponse)
            if !store.state.messages.isEmpty {
                await store.receive(\.messagesUpdated)
            }

            expectNoDifference(store.state.messages, [])
            #expect(!store.state.isLoadingMessages)
            #expect(store.state.isMessageSnapshotEmpty)
            #expect(try #require(store.state.turns).isEmpty)
            #expect(try #require(store.state.rows).isEmpty)
            #expect(store.state.shouldShowEmptyChat)

            await task.cancel()
            continuation.finish()
        }
    }

    @Test("A working empty chat shows progress before its first canonical message")
    func workingEmptyChatShowsProgress() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let session = try makeSession()
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            }

            await store.send(.sessionStatusChanged(.working)) {
                $0.sessionStatusChanged(.working)
            }

            expectNoDifference(
                try #require(store.state.rows).map(DisplayedRowProjection.init),
                [
                    .turnInProgress(
                        id: "\(session.id):pending",
                        startedAt: try #require(session.updatedDate)
                    ),
                ]
            )
        }
    }

    @Test("An initially working chat treats its latest turn as active")
    func initiallyWorkingChatUsesLatestTurn() throws {
        try withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let session = try makeSession(status: "working")
            let message = Message(
                id: "current",
                sessionID: session.id,
                role: .user,
                content: "Current",
                createdAt: Date(timeIntervalSince1970: 1_783_558_800),
                turnID: "current-turn"
            )
            var state = Chat.State(session: session)
            state.turns = Turn.parse(messages: [message])
            state.updateRows()

            expectNoDifference(
                try #require(state.rows).map(DisplayedRowProjection.init),
                [
                    .human(id: message.id, content: "Current"),
                    .turnInProgress(
                        id: "current-turn",
                        startedAt: message.createdAt
                    ),
                ]
            )
        }
    }

    @Test("A correlated canonical message remains active when status arrives second")
    func correlatedMessageBeforeWorkingStatus() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let session = try makeSession()
            let message = Message(
                id: "canonical",
                sessionID: session.id,
                role: .user,
                content: "Run it",
                createdAt: Date(timeIntervalSince1970: 1_783_558_800),
                turnID: "attempt"
            )
            var state = Chat.State(session: session)
            state.beginSendCycle(attemptID: UUID(0))
            state.observeCorrelatedTurn(
                try #require(message.turnID),
                attemptID: UUID(0)
            )
            let store = TestStore(initialState: state) {
                Chat()
            }

            await store.send(.messagesUpdated([message])) {
                $0.isMessageSnapshotEmpty = false
                $0.turns = Turn.parse(messages: [message])
                $0.initializeIdleBaseline()
                $0.updateRows()
            }
            await store.send(.sessionStatusChanged(.working)) {
                $0.sessionStatusChanged(.working)
            }

            expectNoDifference(
                try #require(store.state.rows).map(DisplayedRowProjection.init),
                [
                    .human(id: message.id, content: "Run it"),
                    .turnInProgress(
                        id: "attempt",
                        startedAt: message.createdAt
                    ),
                ]
            )
        }
    }

    @Test("An unconfirmed attempt does not suppress a later active turn")
    func unconfirmedAttemptDoesNotSuppressLaterWork() throws {
        try withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let session = try makeSession()
            let previousMessage = Message(
                id: "previous",
                sessionID: session.id,
                role: .user,
                content: "Previous",
                createdAt: Date(timeIntervalSince1970: 1_783_558_700),
                turnID: "previous-turn"
            )
            let nextMessage = Message(
                id: "next",
                sessionID: session.id,
                role: .user,
                content: "Next",
                createdAt: Date(timeIntervalSince1970: 1_783_558_800),
                turnID: "next-turn"
            )
            var state = Chat.State(session: session)
            state.turns = Turn.parse(messages: [previousMessage])
            state.optimisticMessages = [
                .init(
                    id: UUID(0),
                    workspaceID: session.workspaceID,
                    sessionID: session.id,
                    content: "Unconfirmed",
                    model: session.model,
                    isFastModeEnabled: false,
                    mode: .sent,
                    reasoningEffort: nil,
                    status: .unconfirmed,
                    previousTurnID: "previous-turn"
                ),
            ]
            state.initializeIdleBaseline()
            state.beginSendCycle(attemptID: UUID(0))
            state.sessionStatusChanged(.working)
            state.turns = Turn.parse(
                messages: [previousMessage, nextMessage],
                reusing: state.turns ?? []
            )
            state.updateRows()

            expectNoDifference(
                try #require(state.rows).map(DisplayedRowProjection.init),
                [
                    .human(id: previousMessage.id, content: "Previous"),
                    .human(id: UUID(0).uuidString, content: "Unconfirmed"),
                    .human(id: nextMessage.id, content: "Next"),
                    .turnInProgress(
                        id: "next-turn",
                        startedAt: nextMessage.createdAt
                    ),
                ]
            )
        }
    }

    @Test("Idle status clears a correlated turn before future work")
    func idleStatusClearsCorrelatedTurn() throws {
        try withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let session = try makeSession()
            let message = Message(
                id: "previous",
                sessionID: session.id,
                role: .user,
                content: "Previous",
                createdAt: Date(timeIntervalSince1970: 1_783_558_700),
                turnID: "previous-turn"
            )
            var state = Chat.State(session: session)
            state.turns = Turn.parse(messages: [message])
            state.initializeIdleBaseline()
            state.beginSendCycle(attemptID: UUID(0))
            state.observeCorrelatedTurn(
                "previous-turn",
                attemptID: UUID(0)
            )
            state.sessionStatusChanged(.idle)
            state.sessionStatusChanged(.working)

            expectNoDifference(
                try #require(state.rows).map(DisplayedRowProjection.init),
                [
                    .human(id: message.id, content: "Previous"),
                    .turnInProgress(
                        id: "\(session.id):pending",
                        startedAt: try #require(session.updatedDate)
                    ),
                ]
            )
        }
    }

    @Test("A late canonical observation cannot enter the next work cycle")
    func lateCanonicalObservationDoesNotPoisonNextCycle() throws {
        try withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let session = try makeSession()
            let lateMessage = Message(
                id: "late",
                sessionID: session.id,
                role: .user,
                content: "Late",
                createdAt: Date(timeIntervalSince1970: 1_783_558_700),
                turnID: "late-turn"
            )
            let desktopMessage = Message(
                id: "desktop",
                sessionID: session.id,
                role: .user,
                content: "Desktop",
                createdAt: Date(timeIntervalSince1970: 1_783_558_800),
                turnID: "desktop-turn"
            )
            var state = Chat.State(session: session)
            state.beginSendCycle(attemptID: UUID(0))
            state.sessionStatusChanged(.working)
            state.sessionStatusChanged(.idle)
            state.turns = Turn.parse(messages: [lateMessage])
            state.observeCorrelatedTurn(
                "late-turn",
                attemptID: UUID(0)
            )
            state.turns = Turn.parse(
                messages: [lateMessage, desktopMessage],
                reusing: state.turns ?? []
            )
            state.sessionStatusChanged(.working)

            expectNoDifference(
                try #require(state.rows).map(DisplayedRowProjection.init),
                [
                    .human(id: lateMessage.id, content: "Late"),
                    .human(id: desktopMessage.id, content: "Desktop"),
                    .turnInProgress(
                        id: "desktop-turn",
                        startedAt: desktopMessage.createdAt
                    ),
                ]
            )
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
            store.exhaustivity = .off

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
            await store.finish()
        }
    }

    @Test("An initial queued-only response remains visible without creating a turn")
    func queuedOnlyInitialResponse() async throws {
        let session = try makeSession()
        let message = Message(
            id: "queued",
            sessionID: session.id,
            role: .user,
            content: "Run the tests next",
            createdAt: Date(timeIntervalSince1970: 0),
            queueOrder: 1
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Message.insert { message }.execute(database)
            }
        } operation: {
            var state = Chat.State(session: session)
            try await state.queuedMessages.$messages.load()
            let store = TestStore(initialState: state) {
                Chat()
            }

            await store.send(
                .initialMessagesResponse(
                    sessionID: session.id,
                    messages: [message]
                )
            ) {
                $0.isLoadingMessages = false
                $0.isMessageSnapshotEmpty = true
            }

            #expect(store.state.isMessageSnapshotEmpty)
            #expect(store.state.turns?.isEmpty == true)
            #expect(store.state.rows?.isEmpty == true)
            #expect(!store.state.shouldShowEmptyChat)
            await store.finish()
        }
    }

    @Test("Fetched model settings apply only before compatible user selections")
    func modelSettings() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let session = Session.preview(
                model: .gpt5_5,
                codexThinkingLevel: nil,
                isFastModeEnabled: nil
            )
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            }

            await store.send(
                .modelSettingsFetched(
                    DesktopClient.ModelSettings(
                        defaultModel: .gpt_5_6_sol,
                        defaultReasoningEffort: .low,
                        isFastModeEnabled: true
                    )
                )
            ) {
                $0.isFastModeEnabled = true
                $0.selectedModel = .gpt_5_6_sol
                $0.selectedReasoningEffort = .low
            }
            await store.send(.binding(.set(\.selectedModel, .gpt_5_6_terra))) {
                $0.selectedModel = .gpt_5_6_terra
                $0.hasUserSelectedModel = true
            }
            await store.send(
                .modelSettingsFetched(
                    DesktopClient.ModelSettings(
                        defaultModel: .gpt5_4,
                        defaultReasoningEffort: .low,
                        isFastModeEnabled: false
                    )
                )
            ) {
                $0.isFastModeEnabled = false
            }
            await store.send(
                .modelSettingsFetched(
                    DesktopClient.ModelSettings(
                        defaultModel: .fable5,
                        defaultReasoningEffort: .low,
                        isFastModeEnabled: true
                    )
                )
            ) {
                $0.isFastModeEnabled = true
            }
        }
    }

    @Test("Mobile model settings override Conductor defaults")
    func mobileModelSettingsOverride() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let session = Session.preview(
                model: .gpt5_5,
                codexThinkingLevel: nil,
                isFastModeEnabled: nil
            )
            let state = Chat.State(session: session)
            state.$mobileModelSettingsOverride.withLock {
                $0 = DesktopClient.ModelSettings(
                    defaultModel: .gpt_5_6_terra,
                    defaultReasoningEffort: .ultra,
                    isFastModeEnabled: true
                )
            }
            let store = TestStore(initialState: state) {
                Chat()
            }

            await store.send(
                .modelSettingsFetched(
                    DesktopClient.ModelSettings(
                        defaultModel: .gpt_5_6_sol,
                        defaultReasoningEffort: .low,
                        isFastModeEnabled: false
                    )
                )
            ) {
                $0.isFastModeEnabled = true
                $0.selectedModel = .gpt_5_6_terra
                $0.selectedReasoningEffort = .ultra
            }
        }
    }

    @Test("Persisted empty-session choices are not replaced by fetched defaults")
    func persistedEmptySessionSettings() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let session = Session.preview(
                lastUserMessageAt: nil,
                model: .gpt_5_6_sol,
                codexThinkingLevel: .high,
                isFastModeEnabled: true
            )
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            }

            await store.send(
                .modelSettingsFetched(
                    DesktopClient.ModelSettings(
                        defaultModel: session.model,
                        defaultReasoningEffort: .low,
                        isFastModeEnabled: false
                    )
                )
            )
            expectNoDifference(store.state.selectedReasoningEffort, .high)
            #expect(store.state.isFastModeEnabled)
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
            await store.send(
                .modelSettingsFetched(
                    DesktopClient.ModelSettings(
                        defaultModel: .gpt_5_6_sol,
                        defaultReasoningEffort: .high,
                        isFastModeEnabled: false
                    )
                )
            )
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
            await store.send(
                .modelSettingsFetched(
                    DesktopClient.ModelSettings(
                        defaultModel: .gpt_5_6_sol,
                        defaultReasoningEffort: .high,
                        isFastModeEnabled: false
                    )
                )
            )
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
            await store.send(
                .modelSettingsFetched(
                    DesktopClient.ModelSettings(
                        defaultModel: .gpt5_4,
                        defaultReasoningEffort: .high,
                        isFastModeEnabled: false
                    )
                )
            )
            await store.send(.binding(.set(\.selectedModel, .gpt_5_6_terra))) {
                $0.selectedModel = .gpt_5_6_terra
                $0.hasUserSelectedModel = true
            }
            await store.send(.sessionModelChanged(.gpt5_4))
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
                $0.hasObservedSessionFastModeChange = true
                $0.isFastModeEnabled = false
            }
            await store.send(
                .modelSettingsFetched(
                    DesktopClient.ModelSettings(
                        defaultModel: session.model,
                        defaultReasoningEffort: .medium,
                        isFastModeEnabled: true
                    )
                )
            )
            await store.send(.sessionFastModeChanged(true)) {
                $0.isFastModeEnabled = true
            }
        }
    }

    @Test("Reasoning effort selects a supported option")
    func reasoningEffortSelection() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let store = TestStore(
                initialState: Chat.State(
                    session: .preview(codexThinkingLevel: .ultra)
                )
            ) {
                Chat()
            }

            await store.send(.reasoningEffortSelected(.medium)) {
                $0.hasUserSelectedReasoningEffort = true
                $0.selectedReasoningEffort = .medium
            }
            await store.send(.reasoningEffortSelected(.ultracode))
        }
    }

    @Test("Claude reasoning selects an available option")
    func claudeReasoningEffortSelection() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let store = TestStore(
                initialState: Chat.State(
                    session: .preview(
                        agentType: .claude,
                        model: .fable5,
                        claudeEffortLevel: .ultracode
                    )
                )
            ) {
                Chat()
            }

            await store.send(.reasoningEffortSelected(.low)) {
                $0.hasUserSelectedReasoningEffort = true
                $0.selectedReasoningEffort = .low
            }
            await store.send(.reasoningEffortSelected(.ultra))
        }
    }

    @Test("A newly selected Claude model accepts Ultracode")
    func selectedClaudeModelAcceptsUltracode() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let store = TestStore(
                initialState: Chat.State(
                    session: .preview(codexThinkingLevel: .high),
                    selectedModel: .fable5
                )
            ) {
                Chat()
            }

            await store.send(.reasoningEffortSelected(.ultracode)) {
                $0.hasUserSelectedReasoningEffort = true
                $0.selectedReasoningEffort = .ultracode
            }
        }
    }

    @Test("Changing models replaces an unsupported reasoning effort")
    func reasoningEffortFollowsModel() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let store = TestStore(
                initialState: Chat.State(
                    session: .preview(codexThinkingLevel: .ultra)
                )
            ) {
                Chat()
            }

            await store.send(.binding(.set(\.selectedModel, .gpt_5_6_luna))) {
                $0.selectedModel = .gpt_5_6_luna
                $0.selectedReasoningEffort = .medium
                $0.hasUserSelectedModel = true
            }
            await store.send(.binding(.set(\.selectedModel, .gpt5_5))) {
                $0.selectedModel = .gpt5_5
            }
        }
    }

    @Test("Reasoning effort follows the observed session setting")
    func reasoningEffortFollowsObservedSession() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let store = TestStore(initialState: Chat.State(session: .preview())) {
                Chat()
            }

            await store.send(.sessionReasoningEffortChanged(.max)) {
                $0.hasObservedSessionReasoningEffortChange = true
                $0.selectedReasoningEffort = .max
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
            state.updateRows()
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

private func makeSession(
    id: String = "session-1",
    status: String = "idle"
) throws -> Session {
    try JSONDecoder().decode(
        Session.self,
        from: Data(
            """
            {
              "id": "\(id)",
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

private struct TestError: LocalizedError {
    var errorDescription: String? {
        "Something went wrong."
    }
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))

    while clock.now < deadline {
        if await condition() {
            return
        }
        try? await clock.sleep(for: .milliseconds(10))
    }
    if await condition() {
        return
    }
    Issue.record("Timed out waiting for an asynchronous test condition.")
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
        case .optimisticMessage(let message):
            .human(id: message.id.uuidString, content: message.content)
        case .assistantTextChunk,
             .assistantThinking,
             .assistantToolCall,
             .assistantError:
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

private func humanMessageContent(
    in state: Chat.State,
    id: Message.ID
) -> String? {
    for turn in state.turns ?? [] {
        for row in turn.rows {
            guard case let .humanMessageRow(message) = row,
                  message.id == id else {
                continue
            }
            return message.content
        }
    }
    return nil
}
