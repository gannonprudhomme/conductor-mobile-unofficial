//
//  WorkspaceChatTests.swift
//  ConductorChatTests
//
//  Created by Gannon Prudomme on 7/11/26.
//

import ComposableArchitecture
import ConductorMobileData
import Foundation
import SharedConductorData
@_spi(Internals) import Sharing
import SQLiteData
@testable import ConductorChat
import Testing

@MainActor
struct WorkspaceChatTests {
    @Test("Loading unread sessions marks their workspace as read")
    func loadingUnreadSessionsMarksWorkspaceAsRead() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active", unread: 1)
        let activeSession = try makeSession(
            id: "active",
            workspaceID: workspace.id,
            unreadCount: 3
        )
        let unreadSession = try makeSession(
            id: "unread",
            workspaceID: workspace.id,
            unreadCount: 2
        )

        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Workspace.upsert { workspace }.execute(db)
                try Session.upsert { [activeSession, unreadSession] }.execute(db)
            }
        } operation: {
            @Dependency(\.defaultDatabase) var database

            let requests = LockIsolated<[String]>([])
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.desktopClient.setWorkspaceUnread = { workspaceID, isUnread in
                    requests.withValue { $0.append("\(workspaceID):\(isUnread)") }
                    return .hook
                }
            }

            await store.send(.loadSessionsResponse(.success([activeSession, unreadSession]))) {
                $0.isLoadingSessions = false
            }
            await store.finish()
            #expect(requests.value.isEmpty)

            await store.send(
                .chat(
                    .initialMessagesResponse(
                        sessionID: activeSession.id,
                        messages: []
                    )
                )
            ) {
                $0.chat?.isLoadingMessages = false
                $0.chat?.isMessageSnapshotEmpty = true
            }
            await store.finish()
            #expect(requests.value == ["\(workspace.id):false"])

            try await database.write { db in
                try Session
                    .find(unreadSession.id)
                    .update { $0.unreadCount = 2 }
                    .execute(db)
            }
            await store.send(.sessionButtonTapped(unreadSession)) {
                $0.chat = Chat.State(session: unreadSession)
                $0.hasUserSelectedSession = true
            }
            await store.finish()
            #expect(requests.value == ["\(workspace.id):false"])

            await store.send(
                .chat(
                    .initialMessagesResponse(
                        sessionID: activeSession.id,
                        messages: []
                    )
                )
            )
            #expect(requests.value == ["\(workspace.id):false"])

            await store.send(
                .chat(
                    .initialMessagesResponse(
                        sessionID: unreadSession.id,
                        messages: []
                    )
                )
            ) {
                $0.chat?.isLoadingMessages = false
                $0.chat?.isMessageSnapshotEmpty = true
            }
            await store.finish()

            let cachedUnreadState = try await database.read { db in
                (
                    try Workspace.find(workspace.id).fetchOne(db)?.unread,
                    try Session
                        .where { $0.workspaceID.eq(workspace.id) }
                        .order(by: \.id)
                        .fetchAll(db)
                        .map(\.unreadCount)
                )
            }
            #expect(cachedUnreadState.0 == 0)
            #expect(cachedUnreadState.1 == [0, 0])
            #expect(requests.value == ["\(workspace.id):false", "\(workspace.id):false"])
        }
    }

    @Test("Active sessions match Conductor's creation order")
    func activeSessionsMatchConductorOrder() throws {
        let olderSession = try makeSession(
            id: "older",
            workspaceID: "workspace-1",
            createdAt: "2026-07-09 00:00:00",
            updatedAt: "2026-07-09 03:00:00"
        )
        let newerSession = try makeSession(
            id: "newer",
            workspaceID: "workspace-1",
            createdAt: "2026-07-09 01:00:00",
            updatedAt: "2026-07-09 02:00:00"
        )

        try withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Session.upsert { newerSession }.execute(db)
                try Session.upsert { olderSession }.execute(db)
            }
        } operation: {
            let state = WorkspaceChat.State(
                workspaceWithRepository: WorkspaceWithRepository(
                    workspace: try makeWorkspace(activeSessionID: newerSession.id),
                    repository: nil
                )
            )

            #expect(state.activeSessions.map(\.id) == [olderSession.id, newerSession.id])
        }
    }

    @Test("The active workspace session is selected")
    func activeSessionIsSelected() throws {
        let activeSession = try makeSession(id: "active", workspaceID: "workspace-1")
        let newerSession = try makeSession(
            id: "newer",
            workspaceID: "workspace-1",
            updatedAt: "2026-07-09 02:00:00"
        )

        try withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Session.upsert { activeSession }.execute(db)
                try Session.upsert { newerSession }.execute(db)
            }
        } operation: {
            let workspace = try makeWorkspace(activeSessionID: activeSession.id)
            let state = WorkspaceChat.State(
                workspaceWithRepository: WorkspaceWithRepository(
                    workspace: workspace,
                    repository: nil
                )
            )

            #expect(state.chat?.sessionID == activeSession.id)
        }
    }

    @Test("The first load replaces a cached fallback with the workspace active session")
    func firstLoadReplacesCachedFallback() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let activeSession = try makeSession(id: "active", workspaceID: workspace.id)
        let cachedFallback = try makeSession(id: "cached", workspaceID: workspace.id)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Session.upsert { cachedFallback }.execute(db)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            }

            #expect(store.state.chat?.sessionID == cachedFallback.id)
            #expect(store.state.isLoadingSessions)

            await store.send(.loadSessionsResponse(.success([cachedFallback, activeSession]))) {
                $0.chat = Chat.State(session: activeSession)
                $0.isLoadingSessions = false
            }
        }
    }

    @Test("An active-session update cannot clear a chat before SQLite catches up")
    func activeSessionUpdatePreservesUnpersistedChat() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let activeSession = try makeSession(id: "active", workspaceID: workspace.id)

        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            }

            await store.send(.loadSessionsResponse(.success([activeSession]))) {
                $0.chat = Chat.State(session: activeSession)
                $0.isLoadingSessions = false
            }
            await store.send(.activeSessionIDChanged(activeSession.id))
            #expect(store.state.chat?.sessionID == activeSession.id)
        }
    }

    @Test("A user selection before the first load is preserved")
    func userSelectionBeforeFirstLoadIsPreserved() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let activeSession = try makeSession(id: "active", workspaceID: workspace.id)
        let cachedFallback = try makeSession(id: "cached", workspaceID: workspace.id)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Session.upsert { cachedFallback }.execute(db)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            }

            await store.send(.sessionButtonTapped(cachedFallback)) {
                $0.hasUserSelectedSession = true
            }
            await store.send(.loadSessionsResponse(.success([activeSession, cachedFallback]))) {
                $0.isLoadingSessions = false
            }
        }
    }

    @Test("Later snapshots preserve a valid selection")
    func laterSnapshotsPreserveValidSelection() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let activeSession = try makeSession(id: "active", workspaceID: workspace.id)
        let selectedSession = try makeSession(id: "selected", workspaceID: workspace.id)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Session.upsert { activeSession }.execute(db)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            }

            await store.send(.loadSessionsResponse(.success([activeSession, selectedSession]))) {
                $0.isLoadingSessions = false
            }
            await store.send(.sessionButtonTapped(selectedSession)) {
                $0.hasUserSelectedSession = true
                $0.chat = Chat.State(session: selectedSession)
            }
            await store.send(.loadSessionsResponse(.success([activeSession, selectedSession])))
        }
    }

    @Test("A removed or archived selection falls back to active, then most recent")
    func invalidSelectionFallsBack() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let activeSession = try makeSession(id: "active", workspaceID: workspace.id)
        let selectedSession = try makeSession(id: "selected", workspaceID: workspace.id)
        let olderSession = try makeSession(
            id: "older",
            workspaceID: workspace.id,
            updatedAt: "2026-07-09 02:00:00"
        )
        let newestSession = try makeSession(
            id: "newest",
            workspaceID: workspace.id,
            updatedAt: "2026-07-09 03:00:00"
        )
        let archivedActiveSession = try makeSession(
            id: activeSession.id,
            workspaceID: workspace.id,
            isHidden: true
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Session.upsert { activeSession }.execute(db)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            }

            await store.send(.loadSessionsResponse(.success([activeSession, selectedSession]))) {
                $0.isLoadingSessions = false
            }
            await store.send(.sessionButtonTapped(selectedSession)) {
                $0.hasUserSelectedSession = true
                $0.chat = Chat.State(session: selectedSession)
            }
            await store.send(
                .loadSessionsResponse(.success([olderSession, activeSession, newestSession]))
            ) {
                $0.chat = Chat.State(session: activeSession)
            }
            await store.send(
                .loadSessionsResponse(.success([olderSession, archivedActiveSession, newestSession]))
            ) {
                $0.chat = Chat.State(session: newestSession)
            }
        }
    }

    @Test("Session snapshots update through one connection")
    func sessionSnapshotsUpdateThroughOneConnection() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)
        let replacement = try makeSession(
            id: "replacement",
            workspaceID: workspace.id,
            updatedAt: "2026-07-09 02:00:00"
        )
        let database = try appDatabase()
        try await database.write { db in
            try Session.upsert { session }.execute(db)
        }

        try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            let (stream, continuation) = AsyncThrowingStream<
                [Session],
                any Error
            >.makeStream()
            let connectionCount = LockIsolated(0)
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.desktopClient.observeSessions = { workspaceID in
                    #expect(workspaceID == workspace.id)
                    connectionCount.withValue { $0 += 1 }
                    return stream
                }
            }

            let task = await store.send(.task) {
                $0.hasNormalizedRestoredOutbox = true
            }

            continuation.yield([session])
            await store.receive(\.loadSessionsResponse.success) {
                $0.isLoadingSessions = false
            }
            await store.receive(\.sessionSnapshotPersisted) {
                $0.hasPersistedInitialSessionSnapshot = true
            }

            continuation.yield([replacement])
            await store.receive(\.loadSessionsResponse.success) {
                $0.chat = Chat.State(session: replacement)
            }
            await store.receive(\.sessionSnapshotPersisted)
            #expect(connectionCount.value == 1)

            let storedSessionIDs = try await database.read { db in
                try Session
                    .where { $0.workspaceID.eq(workspace.id) }
                    .fetchAll(db)
                    .map(\.id)
            }
            #expect(storedSessionIDs == [replacement.id])

            await task.cancel()
        }
    }

    @Test("Selecting a session swaps the chat")
    func sessionSelectionSwapsChat() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let activeSession = try makeSession(id: "active", workspaceID: workspace.id)
        let selectedSession = try makeSession(id: "selected", workspaceID: workspace.id)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Session.upsert { activeSession }.execute(db)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            }

            await store.send(.loadSessionsResponse(.success([selectedSession, activeSession]))) {
                $0.isLoadingSessions = false
            }
            await store.send(.sessionButtonTapped(selectedSession)) {
                $0.hasUserSelectedSession = true
                $0.chat = Chat.State(session: selectedSession)
            }
            await store.send(.loadSessionsResponse(.success([activeSession, selectedSession])))
        }
    }

    @Test("Creating a session selects it once and preserves it until observation catches up")
    func sessionCreationSelectsSession() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let activeSession = try makeSession(id: "active", workspaceID: workspace.id)
        let createdSession = try makeSession(id: "created", workspaceID: workspace.id)
        let (responses, responseContinuation) = AsyncStream<Void>.makeStream()
        let requestCount = LockIsolated(0)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { activeSession }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.desktopClient.createSession = { workspaceID in
                    #expect(workspaceID == workspace.id)
                    requestCount.withValue { $0 += 1 }
                    for await _ in responses {
                        return createdSession
                    }
                    throw TestError()
                }
            }

            await store.send(.createSessionButtonTapped) {
                $0.isCreatingSession = true
                $0.sessionIDsBeforeCreation = [activeSession.id]
            }
            await store.send(.createSessionButtonTapped)
            #expect(requestCount.value == 1)

            responseContinuation.yield()
            await store.receive(\.createSessionResponse.success) {
                $0.hasUserSelectedSession = true
                $0.isCreatingSession = false
                $0.sessionIDsBeforeCreation = nil
                $0.sessionIDAwaitingObservation = createdSession.id
                $0.chat = Chat.State(
                    session: createdSession,
                    shouldFocusMessageField: true
                )
            }

            await store.send(.loadSessionsResponse(.success([activeSession]))) {
                $0.isLoadingSessions = false
            }
            await store.send(
                .loadSessionsResponse(.success([activeSession, createdSession]))
            ) {
                $0.sessionIDAwaitingObservation = nil
            }
            #expect(store.state.chat?.sessionID == createdSession.id)
            responseContinuation.finish()
        }
    }

    @Test("Session observation selects a creation before its response arrives")
    func sessionObservationSelectsCreation() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let activeSession = try makeSession(id: "active", workspaceID: workspace.id)
        let createdSession = try makeSession(id: "created", workspaceID: workspace.id)
        let (responses, responseContinuation) = AsyncStream<Void>.makeStream()

        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { activeSession }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.desktopClient.createSession = { _ in
                    for await _ in responses {
                        return createdSession
                    }
                    throw TestError()
                }
            }

            await store.send(.createSessionButtonTapped) {
                $0.isCreatingSession = true
                $0.sessionIDsBeforeCreation = [activeSession.id]
            }
            await store.send(
                .loadSessionsResponse(.success([activeSession, createdSession]))
            ) {
                $0.hasUserSelectedSession = true
                $0.isLoadingSessions = false
                $0.sessionIDsBeforeCreation = nil
                $0.chat = Chat.State(
                    session: createdSession,
                    shouldFocusMessageField: true
                )
            }
            await store.send(.activeSessionIDChanged(activeSession.id))
            #expect(store.state.chat?.sessionID == createdSession.id)

            responseContinuation.yield()
            await store.receive(\.createSessionResponse.success) {
                $0.isCreatingSession = false
            }
            responseContinuation.finish()
        }
    }

    @Test("A session creation failure keeps the current chat and presents an alert")
    func sessionCreationFailure() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let activeSession = try makeSession(id: "active", workspaceID: workspace.id)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { activeSession }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.desktopClient.createSession = { _ in
                    throw TestError()
                }
            }

            await store.send(.createSessionButtonTapped) {
                $0.isCreatingSession = true
                $0.sessionIDsBeforeCreation = [activeSession.id]
            }
            await store.receive(\.createSessionResponse.failure) {
                $0.isCreatingSession = false
                $0.sessionIDsBeforeCreation = nil
                $0.destination = .alert(
                    .failedToCreateSession(message: TestError().localizedDescription)
                )
            }
            #expect(store.state.chat?.sessionID == activeSession.id)
        }
    }

    @Test("Branch rename is prefilled, trimmed, and submitted")
    func branchRename() async throws {
        let workspace = try makeWorkspace(branch: "old-branch")
        let requests = LockIsolated<[String]>([])

        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.desktopClient.renameWorkspaceBranch = { workspaceID, branch in
                    requests.withValue { $0.append("\(workspaceID):\(branch)") }
                }
            }
            store.exhaustivity = .off

            await store.send(.renameBranchButtonTapped) {
                $0.branchNameDraft = "old-branch"
                $0.destination = .renameBranch
            }
            await store.send(.binding(.set(\.branchNameDraft, "  renamed-branch  "))) {
                $0.branchNameDraft = "  renamed-branch  "
            }
            await store.send(.renameBranchSubmitted) {
                $0.branchNameDraft = "renamed-branch"
                $0.destination = nil
                $0.isRenamingBranch = true
            }
            await store.finish()

            #expect(requests.value == ["workspace-1:renamed-branch"])
        }
    }

    @Test("Empty and unchanged branch names are not submitted")
    func invalidBranchRenames() async throws {
        let workspace = try makeWorkspace(branch: "old-branch")
        let requestCount = LockIsolated(0)

        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.desktopClient.renameWorkspaceBranch = { _, _ in
                    requestCount.withValue { $0 += 1 }
                }
            }

            await store.send(.renameBranchButtonTapped) {
                $0.branchNameDraft = "old-branch"
                $0.destination = .renameBranch
            }
            await store.send(.renameBranchSubmitted)
            await store.send(.binding(.set(\.branchNameDraft, "   "))) {
                $0.branchNameDraft = "   "
            }
            await store.send(.renameBranchSubmitted)

            #expect(requestCount.value == 0)
        }
    }

    @Test("Branch rename failures present an alert")
    func branchRenameFailure() async throws {
        let workspace = try makeWorkspace(branch: "old-branch")

        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            var state = WorkspaceChat.State(
                workspaceWithRepository: WorkspaceWithRepository(
                    workspace: workspace,
                    repository: nil
                )
            )
            state.isRenamingBranch = true
            let store = TestStore(
                initialState: state
            ) {
                WorkspaceChat()
            }

            await store.send(.renameBranchResponse(.failure(TestError()))) {
                $0.isRenamingBranch = false
                $0.destination = .alert(
                    .failedToRenameBranch(message: TestError().localizedDescription)
                )
            }
        }
    }

    @Test("Creating a sixth tab presents the local limit without making a request")
    func sessionCreationLimit() async throws {
        let workspace = try makeWorkspace(activeSessionID: "session-0")
        let sessions = try (0..<5).map { index in
            try makeSession(
                id: "session-\(index)",
                workspaceID: workspace.id
            )
        }

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { sessions }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            }

            await store.send(.createSessionButtonTapped) {
                $0.destination = .alert(.maximumTabsReached)
            }
        }
    }

    @Test("Selecting another session does not cancel a message send")
    func sessionSelectionDoesNotCancelMessageSend() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let activeSession = try makeSession(id: "active", workspaceID: workspace.id)
        let selectedSession = try makeSession(id: "selected", workspaceID: workspace.id)
        let (responses, responseContinuation) = AsyncStream<Void>.makeStream()

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Session.upsert { activeSession }.execute(db)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.date.now = Date(timeIntervalSince1970: 1_783_558_800)
                $0.uuid = .incrementing
                $0.desktopClient.sendMessage = {
                    workspaceID, sessionID, message, model, isFastModeEnabled, _ in
                    #expect(workspaceID == workspace.id)
                    #expect(sessionID == activeSession.id)
                    #expect(message == "Run the tests.")
                    #expect(model == activeSession.model)
                    #expect(!isFastModeEnabled)
                    for await _ in responses {
                        return .unknown(reason: "Delivery could not be determined.")
                    }
                    return .unknown(reason: "Delivery could not be determined.")
                }
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            let chat = try #require(store.state.chat)
            chat.$messageDraft.withLock { $0 = "Run the tests." }
            await store.send(.chat(.sendButtonTapped))
            #expect(store.state.chat?.isMessageSendInFlight == true)
            await store.send(.sessionButtonTapped(selectedSession)) {
                $0.hasUserSelectedSession = true
                $0.chat = Chat.State(
                    session: selectedSession,
                    outbox: $0.$outbox
                )
            }

            responseContinuation.yield()
            responseContinuation.finish()
            await store.finish()
            #expect(store.state.chat?.sessionID == selectedSession.id)
            #expect(
                store.state.outbox[workspace.id, activeSession.id]
                    .first?.attempts.first?.state == .unknown
            )
        }
    }

    @Test("Selecting another session does not cancel a stop request")
    func sessionSelectionDoesNotCancelStopRequest() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let activeSession = try makeSession(
            id: "active",
            workspaceID: workspace.id,
            status: "working"
        )
        let selectedSession = try makeSession(id: "selected", workspaceID: workspace.id)
        let (responses, responseContinuation) = AsyncStream<Void>.makeStream()

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Session.upsert { activeSession }.execute(db)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.desktopClient.stopSession = { workspaceID, sessionID in
                    #expect(workspaceID == workspace.id)
                    #expect(sessionID == activeSession.id)
                    for await _ in responses {
                        throw TestError()
                    }
                    throw TestError()
                }
            }

            await store.send(.chat(.stopButtonTapped)) {
                $0.chat?.isStopInFlight = true
            }
            await store.send(.sessionButtonTapped(selectedSession)) {
                $0.hasUserSelectedSession = true
                $0.chat = Chat.State(session: selectedSession)
            }

            responseContinuation.yield()
            await store.receive(\.chat.stopSessionResponse)
            responseContinuation.finish()
            await store.finish()
        }
    }

    @Test("Archived sessions destination is seeded and dismissed")
    func archivedSessionsDestination() async throws {
        let workspace = try makeWorkspace()
        let session = try makeSession(
            id: "archived",
            workspaceID: workspace.id,
            isHidden: true
        )
        let activeSession = try makeSession(id: "active", workspaceID: workspace.id)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Session.upsert { activeSession }.execute(db)
                try Session.upsert { session }.execute(db)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            }

            await store.send(.archivedSessionsButtonTapped) {
                $0.destination = .archivedSessions(
                    ArchivedSessions.State(
                        workspaceID: workspace.id,
                        sessions: [session]
                    )
                )
            }
            await store.send(.destination(.dismiss)) {
                $0.destination = nil
            }
        }
    }

    @Test("Archiving a workspace calls the desktop")
    func archiveWorkspace() async throws {
        let workspace = try makeWorkspace()
        let archivedWorkspaceID = LockIsolated<String?>(nil)

        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.desktopClient.archiveWorkspace = { workspaceID in
                    archivedWorkspaceID.setValue(workspaceID)
                }
            }
            store.exhaustivity = .off

            await store.send(.archiveWorkspaceButtonTapped)
            await store.finish()
            #expect(archivedWorkspaceID.value == workspace.id)
        }
    }

    @Test("Workspace menu actions call the desktop service")
    func workspaceMenuActionsCallDesktopService() async throws {
        let workspace = try makeWorkspace(status: .inProgress)
        let item = WorkspaceWithRepository(
            workspace: workspace,
            repository: nil
        )
        let now = Date(timeIntervalSince1970: 1_783_555_200)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Workspace.insert { workspace }.execute(db)
            }
        } operation: {
            @Dependency(\.defaultDatabase) var database

            let requests = LockIsolated<[String]>([])
            let store = TestStore(
                initialState: WorkspaceChat.State(workspaceWithRepository: item)
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.date.now = now
                $0.desktopClient.setWorkspacePinned = { workspaceID, isPinned in
                    requests.withValue { $0.append("pinned:\(workspaceID):\(isPinned)") }
                    return .hook
                }
                $0.desktopClient.setWorkspaceStatus = { workspaceID, status in
                    requests.withValue {
                        $0.append("status:\(workspaceID):\(status.rawValue)")
                    }
                    return .hook
                }
                $0.desktopClient.setWorkspaceUnread = { workspaceID, isUnread in
                    requests.withValue { $0.append("unread:\(workspaceID):\(isUnread)") }
                    return .hook
                }
            }
            store.exhaustivity = .off

            await store.send(.workspacePinnedButtonTapped)
            await store.finish()

            await store.send(.workspaceStatusButtonTapped(.inReview))
            await store.finish()

            await store.send(.workspaceUnreadButtonTapped)
            await store.finish()

            let updatedWorkspace = try await database.read { db in
                try Workspace.find(workspace.id).fetchOne(db)
            }
            #expect(updatedWorkspace?.pinnedAt == now.ISO8601Format())
            #expect(updatedWorkspace?.manualStatus == Workspace.Status.inReview.rawValue)
            #expect(updatedWorkspace?.unread == 1)
            #expect(
                requests.value == [
                    "pinned:\(workspace.id):true",
                    "status:\(workspace.id):in-review",
                    "unread:\(workspace.id):true",
                ]
            )
        }
    }

    @Test("A failed workspace menu update restores the previous value")
    func failedWorkspaceMenuUpdateRollsBack() async throws {
        let workspace = try makeWorkspace()
        let item = WorkspaceWithRepository(workspace: workspace, repository: nil)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Workspace.insert { workspace }.execute(db)
            }
        } operation: {
            @Dependency(\.defaultDatabase) var database

            let store = TestStore(
                initialState: WorkspaceChat.State(workspaceWithRepository: item)
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.date.now = Date(timeIntervalSince1970: 1_783_555_200)
                $0.desktopClient.setWorkspacePinned = { _, _ in
                    throw TestError()
                }
            }

            await store.send(.workspacePinnedButtonTapped)
            await store.receive(\.workspaceMutationFailed) {
                $0.destination = .alert(
                    .failedToUpdateWorkspace(message: TestError().localizedDescription)
                )
            }

            let updatedWorkspace = try await database.read { db in
                try Workspace.find(workspace.id).fetchOne(db)
            }
            #expect(updatedWorkspace?.pinnedAt == nil)
        }
    }

    @Test("A workspace menu SQLite fallback presents a warning")
    func workspaceMenuFallbackPresentsWarning() async throws {
        let workspace = try makeWorkspace()
        let item = WorkspaceWithRepository(workspace: workspace, repository: nil)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Workspace.insert { workspace }.execute(db)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(workspaceWithRepository: item)
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.date.now = Date(timeIntervalSince1970: 1_783_555_200)
                $0.desktopClient.setWorkspacePinned = { _, _ in .sqliteFallback }
            }

            await store.send(.workspacePinnedButtonTapped)
            await store.receive(\.workspaceMutationUsedSQLiteFallback) {
                $0.destination = .alert(.workspaceMutationUsedSQLiteFallback)
            }
        }
    }

    @Test("When chat fails to load messages, an alert is presented and dismissed")
    func chatFailsToLoadMessages() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let activeSession = try makeSession(id: "active", workspaceID: workspace.id)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Session.upsert { activeSession }.execute(db)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            }

            await store.send(.chat(.loadMessagesFailed(TestError()))) {
                $0.destination = .alert(
                    .failedToLoadMessages(message: TestError().localizedDescription)
                )
            }
            await store.send(.destination(.dismiss)) {
                $0.destination = nil
            }
        }
    }

    @Test("When chat fails to stop a session, an alert is presented and dismissed")
    func chatFailsToStopSession() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let activeSession = try makeSession(
            id: "active",
            workspaceID: workspace.id,
            status: "working"
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Session.upsert { activeSession }.execute(db)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            }

            await store.send(
                .chat(
                    .stopSessionResponse(
                        sessionID: activeSession.id,
                        result: .failure(TestError())
                    )
                )
            ) {
                $0.destination = .alert(
                    .failedToStopSession(message: TestError().localizedDescription)
                )
            }
            await store.send(.destination(.dismiss)) {
                $0.destination = nil
            }
        }
    }

    @Test("A stop failure is ignored after the stopped session was observed")
    func observedStopSuppressesFailure() async throws {
        let workspace = Workspace.preview(activeSessionID: "active")
        let activeSession = Session.preview(
            id: "active",
            workspaceID: workspace.id
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { activeSession }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            }

            await store.send(
                .chat(
                    .stopSessionResponse(
                        sessionID: activeSession.id,
                        result: .failure(TestError())
                    )
                )
            )
        }
    }

    @Test("Observation connection failures do not alert but command failures do")
    func connectionFailurePresentation() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let activeSession = try makeSession(
            id: "active",
            workspaceID: workspace.id,
            status: "working"
        )
        let error = URLError(.networkConnectionLost)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Session.upsert { activeSession }.execute(db)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            }

            await store.send(.loadSessionsResponse(.failure(error)))
            await store.send(.chat(.loadMessagesFailed(error)))
            await store.send(
                .chat(
                    .stopSessionResponse(
                        sessionID: activeSession.id,
                        result: .failure(error)
                    )
                )
            ) {
                $0.destination = .alert(
                    .failedToStopSession(message: error.localizedDescription)
                )
            }
        }
    }

    @Test("Session observation presents failures, retries, and cancels its connection")
    func sessionObservationRetriesAndCancels() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let activeSession = try makeSession(id: "active", workspaceID: workspace.id)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Session.upsert { activeSession }.execute(db)
            }
        } operation: {
            let clock = TestClock()
            let (firstStream, firstContinuation) = AsyncThrowingStream<
                [Session],
                any Error
            >.makeStream()
            let (secondStream, secondContinuation) = AsyncThrowingStream<
                [Session],
                any Error
            >.makeStream()
            let connectionCount = LockIsolated(0)
            let secondConnectionCancelled = LockIsolated(false)
            secondContinuation.onTermination = { termination in
                guard case .cancelled = termination else {
                    return
                }

                secondConnectionCancelled.setValue(true)
            }
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.continuousClock = clock
                $0.desktopClient.observeSessions = { workspaceID in
                    #expect(workspaceID == workspace.id)
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

            let task = await store.send(.task) {
                $0.hasNormalizedRestoredOutbox = true
            }

            firstContinuation.finish(throwing: TestError())
            await store.receive(\.loadSessionsResponse.failure) {
                $0.destination = .alert(
                    .failedToLoadSessions(message: TestError().localizedDescription)
                )
            }
            #expect(connectionCount.value == 1)

            await clock.advance(by: .seconds(1))
            secondContinuation.yield([activeSession])
            await store.receive(\.loadSessionsResponse.success) {
                $0.isLoadingSessions = false
            }
            await store.receive(\.sessionSnapshotPersisted) {
                $0.hasPersistedInitialSessionSnapshot = true
            }
            #expect(connectionCount.value == 2)

            await task.cancel()
            #expect(secondConnectionCancelled.value)
        }
    }

    @Test("A failed initial outbox save retains the draft and never posts")
    func initialSaveFailure() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)
        @Shared(FailingOutboxKey()) var outbox = MessageOutbox()
        let requestCount = LockIsolated(0)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(workspace: workspace, repository: nil),
                    outbox: $outbox
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.date.now = Date(timeIntervalSince1970: 1_783_558_800)
                $0.desktopClient.sendMessage = { _, _, _, _, _, _ in
                    requestCount.withValue { $0 += 1 }
                    return .accepted(messageID: "unexpected")
                }
                $0.uuid = .incrementing
            }
            store.exhaustivity = .off(showSkippedAssertions: false)
            store.state.chat?.$messageDraft.withLock { $0 = "  Run the tests.  " }

            await store.send(.chat(.sendButtonTapped))
            await store.finish()

            #expect(requestCount.value == 0)
            #expect(store.state.chat?.messageDraft == "  Run the tests.  ")
            #expect(store.state.outbox[workspace.id, session.id].isEmpty)
            #expect(store.state.$outbox.saveError != nil)
        }
    }

    @Test("Editing while the explicit save is suspended preserves the new draft")
    func editedDraftDuringSave() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)
        let saveGate = OutboxSaveGate()
        @Shared(SuspendingOutboxKey(gate: saveGate)) var outbox = MessageOutbox()
        let request = LockIsolated<RecordedSend?>(nil)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(workspace: workspace, repository: nil),
                    outbox: $outbox
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.date.now = Date(timeIntervalSince1970: 1_783_558_800)
                $0.desktopClient.sendMessage = {
                    _, _, message, model, isFastModeEnabled, attemptID in
                    request.setValue(
                        .init(
                            message: message,
                            model: model,
                            isFastModeEnabled: isFastModeEnabled,
                            attemptID: attemptID
                        )
                    )
                    return .accepted(messageID: "message-1")
                }
                $0.uuid = .incrementing
            }
            store.exhaustivity = .off(showSkippedAssertions: false)
            store.state.chat?.$messageDraft.withLock { $0 = "  Run the tests.  " }
            await store.send(.chat(.fastModeButtonTapped))

            await store.send(.chat(.sendButtonTapped))
            try await saveGate.waitUntilSuspended()
            store.state.chat?.$messageDraft.withLock { $0 = "Only run unit tests." }
            saveGate.succeed()
            await store.finish()

            #expect(store.state.chat?.messageDraft == "Only run unit tests.")
            #expect(request.value?.message == "Run the tests.")
            #expect(request.value?.model == session.model)
            #expect(request.value?.isFastModeEnabled == true)
            #expect(
                store.state.outbox[workspace.id, session.id]
                    .first?.attempts.first?.state == .accepted(messageID: "message-1")
            )
        }
    }

    @Test("A partial snapshot preserves the order of two outbound messages")
    func partialCanonicalizationPreservesOutboundOrder() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)
        let initialMessage = Message(
            id: "message-0",
            sessionID: session.id,
            role: .user,
            content: "Initial message",
            createdAt: Date(timeIntervalSince1970: 1_783_558_600),
            turnID: "turn-0"
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(workspace: workspace, repository: nil)
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.date.now = Date(timeIntervalSince1970: 1_783_558_700)
                $0.desktopClient.sendMessage = {
                    _, _, message, _, _, _ in
                    .accepted(messageID: message == "Message A" ? "message-a" : "message-b")
                }
                $0.uuid = .incrementing
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            await store.send(.chat(.messagesUpdated([initialMessage])))

            store.state.chat?.$messageDraft.withLock { $0 = "Message A" }
            await store.send(.chat(.sendButtonTapped))
            await store.finish()
            let firstBubble = try #require(
                store.state.outbox[workspace.id, session.id].first
            )
            let firstAttemptID = try #require(firstBubble.attempts.first?.attemptID)

            store.state.chat?.$messageDraft.withLock { $0 = "Message B" }
            await store.send(.chat(.sendButtonTapped))
            await store.finish()
            let secondBubble = try #require(
                store.state.outbox[workspace.id, session.id].last
            )
            #expect(secondBubble.precedingBubbleID == firstBubble.bubbleID)
            #expect(secondBubble.precedingTurnID == initialMessage.turnID)

            let canonicalFirstMessage = Message(
                id: "message-a",
                sessionID: session.id,
                role: .user,
                content: firstBubble.content,
                createdAt: Date(timeIntervalSince1970: 1_783_558_800),
                turnID: firstAttemptID.uuidString
            )
            await store.send(
                .chat(.messagesUpdated([initialMessage, canonicalFirstMessage]))
            )
            await store.finish()

            #expect(
                store.state.chat?.rows?.map(\.id) == [
                    "human:\(initialMessage.id)",
                    "human:\(firstBubble.bubbleID.uuidString)",
                    "human:\(secondBubble.bubbleID.uuidString)",
                ]
            )
        }
    }

    @Test("Retry uses persisted content and model without touching the draft")
    func retryUsesPersistedBubble() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)
        let bubbleID = UUID(10)
        let originalAttemptID = UUID(11)
        var initialOutbox = MessageOutbox()
        initialOutbox[workspace.id, session.id] = [
            .init(
                bubbleID: bubbleID,
                content: "Persisted content",
                createdAt: Date(timeIntervalSince1970: 1_783_558_700),
                isFastModeEnabled: true,
                model: .gpt_5_6_terra,
                attempts: [.init(attemptID: originalAttemptID, state: .rejected)]
            ),
        ]
        let outbox = Shared(
            wrappedValue: initialOutbox,
            .inMemory("retry-outbox-\(UUID())")
        )
        let request = LockIsolated<RecordedSend?>(nil)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(workspace: workspace, repository: nil),
                    outbox: outbox
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.desktopClient.sendMessage = {
                    _, _, message, model, isFastModeEnabled, attemptID in
                    request.setValue(
                        .init(
                            message: message,
                            model: model,
                            isFastModeEnabled: isFastModeEnabled,
                            attemptID: attemptID
                        )
                    )
                    return .rejected(reason: "Not enqueued.")
                }
                $0.uuid = .incrementing
            }
            store.exhaustivity = .off(showSkippedAssertions: false)
            store.state.chat?.$messageDraft.withLock { $0 = "Unrelated draft" }

            await store.send(.chat(.retryButtonTapped(bubbleID)))
            await store.finish()

            #expect(request.value?.message == "Persisted content")
            #expect(request.value?.model == .gpt_5_6_terra)
            #expect(request.value?.isFastModeEnabled == true)
            #expect(request.value?.attemptID != originalAttemptID)
            #expect(store.state.chat?.messageDraft == "Unrelated draft")
            #expect(
                store.state.outbox[workspace.id, session.id]
                    .first?.attempts.map(\.state) == [.rejected, .rejected]
            )
        }
    }

    @Test("Retry presentation and reducer use the same session-wide eligibility")
    func retryEligibility() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)
        let mixedBubbleID = UUID(60)
        let retryableBubbleID = UUID(63)
        var initialOutbox = MessageOutbox()
        initialOutbox[workspace.id, session.id] = [
            .init(
                bubbleID: mixedBubbleID,
                content: "Accepted with uncertainty",
                createdAt: Date(timeIntervalSince1970: 1_783_558_700),
                isFastModeEnabled: false,
                model: session.model,
                attempts: [
                    .init(
                        attemptID: UUID(61),
                        state: .accepted(messageID: "message-1")
                    ),
                    .init(attemptID: UUID(62), state: .unknown),
                ]
            ),
            .init(
                bubbleID: retryableBubbleID,
                content: "Not sent",
                createdAt: Date(timeIntervalSince1970: 1_783_558_800),
                isFastModeEnabled: false,
                model: session.model,
                attempts: [
                    .init(attemptID: UUID(64), state: .rejected),
                ]
            ),
            .init(
                bubbleID: UUID(65),
                content: "Sending",
                createdAt: Date(timeIntervalSince1970: 1_783_558_900),
                isFastModeEnabled: false,
                model: session.model,
                attempts: [
                    .init(attemptID: UUID(66), state: .sending),
                ]
            ),
        ]
        let outbox = Shared(
            wrappedValue: initialOutbox,
            .inMemory("retry-eligibility-outbox-\(UUID())")
        )
        let requestCount = LockIsolated(0)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
            }
        } operation: {
            var state = WorkspaceChat.State(
                workspaceWithRepository: .init(workspace: workspace, repository: nil),
                outbox: outbox
            )
            state.chat?.updateRows(sessionStatus: session.status)
            let store = TestStore(
                initialState: state
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.desktopClient.sendMessage = { _, _, _, _, _, _ in
                    requestCount.withValue { $0 += 1 }
                    return .accepted(messageID: "unexpected")
                }
            }

            let rows = try #require(store.state.chat?.rows)
            let mixedMessage = try #require(
                rows.compactMap { row -> DisplayedChatRow.OptimisticMessage? in
                    guard case .optimisticMessage(let message) = row.content,
                          message.id == mixedBubbleID else {
                        return nil
                    }
                    return message
                }.first
            )
            let rejectedMessage = try #require(
                rows.compactMap { row -> DisplayedChatRow.OptimisticMessage? in
                    guard case .optimisticMessage(let message) = row.content,
                          message.id == retryableBubbleID else {
                        return nil
                    }
                    return message
                }.first
            )
            #expect(mixedMessage.status == .unknown)
            #expect(!mixedMessage.canRetry)
            #expect(!rejectedMessage.canRetry)

            await store.send(.chat(.retryButtonTapped(mixedBubbleID)))
            await store.send(.chat(.retryButtonTapped(retryableBubbleID)))

            #expect(store.state.destination == nil)
            #expect(requestCount.value == 0)
        }
    }

    @Test("Canonical delivery cancels a retry while its outbox save is suspended")
    func canonicalDeliveryDuringRetrySave() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)
        let bubbleID = UUID(12)
        let originalAttemptID = UUID(13)
        let message = Message(
            id: "message-1",
            sessionID: session.id,
            role: .user,
            content: "Persisted content",
            createdAt: Date(timeIntervalSince1970: 1_783_558_800),
            turnID: originalAttemptID.uuidString
        )
        var initialOutbox = MessageOutbox()
        initialOutbox[workspace.id, session.id] = [
            .init(
                bubbleID: bubbleID,
                content: "Persisted content",
                createdAt: Date(timeIntervalSince1970: 1_783_558_700),
                isFastModeEnabled: true,
                model: .gpt_5_6_terra,
                attempts: [.init(attemptID: originalAttemptID, state: .unknown)]
            ),
        ]
        let saveGate = OutboxSaveGate()
        @Shared(SuspendingOutboxKey(gate: saveGate)) var outbox = initialOutbox
        let requestCount = LockIsolated(0)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(workspace: workspace, repository: nil),
                    outbox: $outbox
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.desktopClient.sendMessage = { _, _, _, _, _, _ in
                    requestCount.withValue { $0 += 1 }
                    return .accepted(messageID: "unexpected")
                }
                $0.uuid = .incrementing
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            await store.send(.chat(.retryButtonTapped(bubbleID)))
            await store.send(.destination(.presented(.alert(.confirmUnknownRetry))))
            try await saveGate.waitUntilSuspended()

            await store.send(.chat(.messagesUpdated([message])))
            #expect(
                store.state.outbox[workspace.id, session.id]
                    .first?.attempts.first?.state == .accepted(messageID: message.id)
            )
            saveGate.succeed()
            await store.finish()

            #expect(requestCount.value == 0)
            #expect(store.state.messageIDToBubbleID[message.id] == bubbleID)
            #expect(store.state.outbox[workspace.id, session.id].isEmpty)
        }
    }

    @Test("A retry save failure releases a canonical message's syncing state")
    func canonicalDeliveryDuringFailedRetrySave() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)
        let bubbleID = UUID(70)
        let originalAttemptID = UUID(71)
        let message = Message(
            id: "message-1",
            sessionID: session.id,
            role: .user,
            content: "Persisted content",
            createdAt: Date(timeIntervalSince1970: 1_783_558_800),
            turnID: originalAttemptID.uuidString
        )
        var initialOutbox = MessageOutbox()
        initialOutbox[workspace.id, session.id] = [
            .init(
                bubbleID: bubbleID,
                content: "Persisted content",
                createdAt: Date(timeIntervalSince1970: 1_783_558_700),
                isFastModeEnabled: true,
                model: .gpt_5_6_terra,
                attempts: [.init(attemptID: originalAttemptID, state: .unknown)]
            ),
        ]
        let saveGate = OutboxSaveGate()
        @Shared(SuspendingOutboxKey(gate: saveGate)) var outbox = initialOutbox
        let requestCount = LockIsolated(0)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
            }
            $0.desktopClient.sendMessage = { _, _, _, _, _, _ in
                requestCount.withValue { $0 += 1 }
                return .accepted(messageID: "unexpected")
            }
            $0.uuid = .incrementing
        } operation: {
            let store = Store(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(workspace: workspace, repository: nil),
                    outbox: $outbox
                )
            ) {
                WorkspaceChat()
            }

            store.send(.chat(.retryButtonTapped(bubbleID)))
            let sendTask = store.send(
                .destination(.presented(.alert(.confirmUnknownRetry)))
            )
            try await saveGate.waitUntilSuspended()

            store.send(.chat(.messagesUpdated([message])))
            saveGate.fail()
            await sendTask.finish()

            #expect(requestCount.value == 0)
            #expect(store.state.messageIDToBubbleID[message.id] == bubbleID)
            #expect(store.state.outbox[workspace.id, session.id].isEmpty)
            #expect(store.state.chat?.outbox[workspace.id, session.id].isEmpty == true)
            let row = try #require(store.state.chat?.rows?.first)
            #expect(
                row.content == .humanMessage(
                    .init(id: bubbleID.uuidString, content: "Persisted content")
                )
            )
        }
    }

    @Test("Restoration normalizes sending to unknown but session switching does not")
    func restorationNormalization() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let activeSession = try makeSession(id: "active", workspaceID: workspace.id)
        let otherSession = try makeSession(id: "other", workspaceID: workspace.id)
        var initialOutbox = MessageOutbox()
        initialOutbox[workspace.id, activeSession.id] = [
            .init(
                bubbleID: UUID(20),
                content: "Sending",
                createdAt: Date(timeIntervalSince1970: 1_783_558_700),
                isFastModeEnabled: false,
                model: activeSession.model,
                attempts: [.init(attemptID: UUID(21), state: .sending)]
            ),
        ]
        let outbox = Shared(
            wrappedValue: initialOutbox,
            .inMemory("restored-outbox-\(UUID())")
        )
        let (sessions, sessionsContinuation) = AsyncThrowingStream<
            [Session],
            any Error
        >.makeStream()
        defer { sessionsContinuation.finish() }

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { [activeSession, otherSession] }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(workspace: workspace, repository: nil),
                    outbox: outbox
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.desktopClient.observeSessions = { _ in sessions }
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            await store.send(.sessionButtonTapped(otherSession))
            #expect(
                store.state.outbox[workspace.id, activeSession.id]
                    .first?.attempts.first?.state == .sending
            )
            let task = await store.send(.task)
            #expect(
                store.state.outbox[workspace.id, activeSession.id]
                    .first?.attempts.first?.state == .unknown
            )
            await task.cancel()
        }
    }

    @Test("Canonical confirmation installs the alias before durable removal")
    func canonicalAliasAndRemoval() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)
        let bubbleID = UUID(30)
        let acceptedAttemptID = UUID(31)
        let retryAttemptID = UUID(32)
        let message = Message(
            id: "message-1",
            sessionID: session.id,
            role: .user,
            content: "Run the tests.",
            createdAt: Date(timeIntervalSince1970: 1_783_558_800),
            turnID: acceptedAttemptID.uuidString
        )
        var initialOutbox = MessageOutbox()
        initialOutbox[workspace.id, session.id] = [
            .init(
                bubbleID: bubbleID,
                content: "Run the tests.",
                createdAt: Date(timeIntervalSince1970: 1_783_558_700),
                isFastModeEnabled: false,
                model: session.model,
                attempts: [
                    .init(attemptID: acceptedAttemptID, state: .accepted(messageID: message.id)),
                    .init(attemptID: retryAttemptID, state: .sending),
                ]
            ),
        ]
        let outbox = Shared(
            wrappedValue: initialOutbox,
            .inMemory("canonical-outbox-\(UUID())")
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
                try Message.upsert { message }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(workspace: workspace, repository: nil),
                    outbox: outbox
                )
            ) {
                WorkspaceChat()
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            await store.send(.chat(.messagesUpdated([message])))
            #expect(store.state.messageIDToBubbleID[message.id] == bubbleID)
            #expect(store.state.outbox[workspace.id, session.id].count == 1)
            #expect(store.state.chat?.rows?.map(\.id).contains("human:\(bubbleID)") == true)

            await store.send(
                .messageSendResponse(
                    .init(
                        workspaceID: workspace.id,
                        sessionID: session.id,
                        bubbleID: bubbleID,
                        attemptID: retryAttemptID
                    ),
                    .rejected(reason: "Not enqueued.")
                )
            )
            await store.finish()
            #expect(store.state.messageIDToBubbleID[message.id] == bubbleID)
            #expect(store.state.outbox[workspace.id, session.id].isEmpty)
        }
    }

    @Test("Canonical messages retain and surface an unknown retry")
    func canonicalMessageRetainsUnknownRetry() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)
        let bubbleID = UUID(33)
        let acceptedAttemptID = UUID(34)
        let retryAttemptID = UUID(35)
        let message = Message(
            id: "message-unknown-retry",
            sessionID: session.id,
            role: .user,
            content: "Run the tests.",
            createdAt: Date(timeIntervalSince1970: 1_783_558_800),
            turnID: acceptedAttemptID.uuidString
        )
        let retryCanonicalMessage = Message(
            id: "message-duplicate",
            sessionID: session.id,
            role: .user,
            content: "Run the tests.",
            createdAt: Date(timeIntervalSince1970: 1_783_558_900),
            turnID: retryAttemptID.uuidString
        )
        var initialOutbox = MessageOutbox()
        initialOutbox[workspace.id, session.id] = [
            .init(
                bubbleID: bubbleID,
                content: "Run the tests.",
                createdAt: Date(timeIntervalSince1970: 1_783_558_700),
                isFastModeEnabled: false,
                model: session.model,
                attempts: [
                    .init(attemptID: acceptedAttemptID, state: .accepted(messageID: message.id)),
                    .init(attemptID: retryAttemptID, state: .sending),
                ]
            ),
        ]
        let outbox = Shared(
            wrappedValue: initialOutbox,
            .inMemory("canonical-unknown-retry-outbox-\(UUID())")
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
                try Message.upsert { message }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(workspace: workspace, repository: nil),
                    outbox: outbox
                )
            ) {
                WorkspaceChat()
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            await store.send(.chat(.messagesUpdated([message])))
            await store.send(
                .messageSendResponse(
                    .init(
                        workspaceID: workspace.id,
                        sessionID: session.id,
                        bubbleID: bubbleID,
                        attemptID: retryAttemptID
                    ),
                    .unknown(reason: "Timed out.")
                )
            )
            await store.finish()

            let bubble = try #require(
                store.state.outbox[workspace.id, session.id].first
            )
            #expect(bubble.bubbleID == bubbleID)
            #expect(
                bubble.attempts == [
                    .init(
                        attemptID: acceptedAttemptID,
                        state: .accepted(messageID: message.id)
                    ),
                    .init(attemptID: retryAttemptID, state: .unknown),
                ]
            )
            #expect(store.state.messageIDToBubbleID[message.id] == bubbleID)
            let row = try #require(store.state.chat?.rows?.first)
            guard case .optimisticMessage(let optimisticMessage) = row.content else {
                Issue.record("Expected the canonical row to surface delivery uncertainty")
                return
            }
            #expect(optimisticMessage.id == bubbleID)
            #expect(optimisticMessage.status == .unknown)

            await store.send(
                .chat(.messagesUpdated([message, retryCanonicalMessage]))
            )
            await store.finish()

            #expect(store.state.outbox[workspace.id, session.id].isEmpty)
            #expect(store.state.messageIDToBubbleID[message.id] == bubbleID)
            #expect(store.state.messageIDToBubbleID[retryCanonicalMessage.id] == nil)
        }
    }

    @Test("An accepted retry remains durable until its canonical row arrives")
    func acceptedRetryWaitsForCanonicalMessage() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)
        let bubbleID = UUID(50)
        let acceptedAttemptID = UUID(51)
        let retryAttemptID = UUID(52)
        let acceptedMessage = Message(
            id: "accepted-message",
            sessionID: session.id,
            role: .user,
            content: "Run the tests.",
            createdAt: Date(timeIntervalSince1970: 1_783_558_800),
            turnID: acceptedAttemptID.uuidString
        )
        let retryMessage = Message(
            id: "retry-message",
            sessionID: session.id,
            role: .user,
            content: "Run the tests.",
            createdAt: Date(timeIntervalSince1970: 1_783_558_900),
            turnID: retryAttemptID.uuidString
        )
        var initialOutbox = MessageOutbox()
        initialOutbox[workspace.id, session.id] = [
            .init(
                bubbleID: bubbleID,
                content: "Run the tests.",
                createdAt: Date(timeIntervalSince1970: 1_783_558_700),
                isFastModeEnabled: false,
                model: session.model,
                attempts: [
                    .init(
                        attemptID: acceptedAttemptID,
                        state: .accepted(messageID: acceptedMessage.id)
                    ),
                    .init(attemptID: retryAttemptID, state: .sending),
                ]
            ),
        ]
        let outbox = Shared(
            wrappedValue: initialOutbox,
            .inMemory("accepted-retry-outbox-\(UUID())")
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(workspace: workspace, repository: nil),
                    outbox: outbox
                )
            ) {
                WorkspaceChat()
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            await store.send(.chat(.messagesUpdated([acceptedMessage])))
            await store.send(
                .messageSendResponse(
                    .init(
                        workspaceID: workspace.id,
                        sessionID: session.id,
                        bubbleID: bubbleID,
                        attemptID: retryAttemptID
                    ),
                    .accepted(messageID: retryMessage.id)
                )
            )
            await store.finish()

            let bubble = try #require(
                store.state.outbox[workspace.id, session.id].first
            )
            #expect(
                bubble.attempts == [
                    .init(
                        attemptID: acceptedAttemptID,
                        state: .accepted(messageID: acceptedMessage.id)
                    ),
                    .init(
                        attemptID: retryAttemptID,
                        state: .accepted(messageID: retryMessage.id)
                    ),
                ]
            )
            let row = try #require(store.state.chat?.rows?.first)
            guard case .optimisticMessage(let optimisticMessage) = row.content else {
                Issue.record("Expected the canonical row to retain syncing state")
                return
            }
            #expect(optimisticMessage.status == .accepted)
            #expect(!optimisticMessage.canRetry)

            await store.send(
                .chat(.messagesUpdated([acceptedMessage, retryMessage]))
            )
            await store.finish()

            #expect(store.state.outbox[workspace.id, session.id].isEmpty)
        }
    }

    @Test("Exact attempt IDs win over an older identical provisional message")
    func exactAttemptIDWinsOverOlderIdenticalMessage() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)
        let bubbleID = UUID(36)
        let attemptID = UUID(37)
        let bubbleCreatedAt = Date(timeIntervalSince1970: 1_783_558_700)
        let olderMessage = Message(
            id: "older-message",
            sessionID: session.id,
            role: .user,
            content: "Run the tests.",
            createdAt: bubbleCreatedAt.addingTimeInterval(1),
            turnID: "older-message"
        )
        let currentMessage = Message(
            id: "current-message",
            sessionID: session.id,
            role: .user,
            content: "Run the tests.",
            createdAt: bubbleCreatedAt.addingTimeInterval(2),
            turnID: attemptID.uuidString
        )
        var initialOutbox = MessageOutbox()
        initialOutbox[workspace.id, session.id] = [
            .init(
                bubbleID: bubbleID,
                content: "Run the tests.",
                createdAt: bubbleCreatedAt,
                isFastModeEnabled: false,
                model: session.model,
                attempts: [.init(attemptID: attemptID, state: .sending)]
            ),
        ]
        let outbox = Shared(
            wrappedValue: initialOutbox,
            .inMemory("exact-attempt-order-outbox-\(UUID())")
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(workspace: workspace, repository: nil),
                    outbox: outbox
                )
            ) {
                WorkspaceChat()
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            await store.send(
                .chat(.messagesUpdated([olderMessage, currentMessage]))
            )
            await store.finish()

            #expect(store.state.messageIDToBubbleID[olderMessage.id] == nil)
            #expect(store.state.messageIDToBubbleID[currentMessage.id] == bubbleID)
            #expect(store.state.outbox[workspace.id, session.id].isEmpty)
        }
    }

    @Test("Same-content messages without durable IDs do not claim a bubble")
    func sameContentMessageDoesNotClaimBubble() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)
        let bubbleID = UUID(38)
        let bubbleCreatedAt = Date(timeIntervalSince1970: 1_783_558_800)
        let message = Message(
            id: "historical-message",
            sessionID: session.id,
            role: .user,
            content: "Run the tests.",
            createdAt: bubbleCreatedAt.addingTimeInterval(-1),
            turnID: "historical-message"
        )
        var initialOutbox = MessageOutbox()
        initialOutbox[workspace.id, session.id] = [
            .init(
                bubbleID: bubbleID,
                content: "Run the tests.",
                createdAt: bubbleCreatedAt,
                isFastModeEnabled: false,
                model: session.model,
                attempts: [.init(attemptID: UUID(39), state: .sending)]
            ),
        ]
        let outbox = Shared(
            wrappedValue: initialOutbox,
            .inMemory("stale-provisional-outbox-\(UUID())")
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(workspace: workspace, repository: nil),
                    outbox: outbox
                )
            ) {
                WorkspaceChat()
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            await store.send(.chat(.messagesUpdated([message])))

            #expect(store.state.messageIDToBubbleID[message.id] == nil)
            #expect(store.state.outbox[workspace.id, session.id].count == 1)
        }
    }

    @Test("An independent same-content message cannot cancel a send before its POST")
    func sameContentMessageDuringOutboxSaveDoesNotCancelSend() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)
        let message = Message(
            id: "message-1",
            sessionID: session.id,
            role: .user,
            content: "Run the tests.",
            createdAt: Date(timeIntervalSince1970: 1_783_558_800),
            turnID: "message-1"
        )
        let saveGate = OutboxSaveGate()
        @Shared(SuspendingOutboxKey(gate: saveGate)) var outbox = MessageOutbox()
        let requestCount = LockIsolated(0)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(workspace: workspace, repository: nil),
                    outbox: $outbox
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.date.now = Date(timeIntervalSince1970: 1_783_558_700)
                $0.desktopClient.sendMessage = { _, _, _, _, _, _ in
                    requestCount.withValue { $0 += 1 }
                    return .accepted(messageID: "current-message")
                }
                $0.uuid = .incrementing
            }
            store.exhaustivity = .off(showSkippedAssertions: false)
            store.state.chat?.$messageDraft.withLock { $0 = "Run the tests." }

            await store.send(.chat(.sendButtonTapped))
            try await saveGate.waitUntilSuspended()
            await store.send(.chat(.messagesUpdated([message])))

            #expect(store.state.messageIDToBubbleID[message.id] == nil)
            #expect(
                store.state.outbox[workspace.id, session.id]
                    .first?.attempts.first?.state == .sending
            )

            saveGate.succeed()
            await store.finish()

            #expect(requestCount.value == 1)
            #expect(
                store.state.outbox[workspace.id, session.id]
                    .first?.attempts.first?.state
                    == .accepted(messageID: "current-message")
            )
        }
    }

    @Test("A provisional canonical message does not guess between matching sending bubbles")
    func ambiguousProvisionalCanonicalMessageDoesNotClaimBubble() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)
        let message = Message(
            id: "message-1",
            sessionID: session.id,
            role: .user,
            content: "Same content",
            createdAt: Date(timeIntervalSince1970: 1_783_558_800),
            turnID: "message-1"
        )
        var initialOutbox = MessageOutbox()
        initialOutbox[workspace.id, session.id] = [UUID(42), UUID(44)].enumerated().map {
            offset,
            bubbleID in
            MessageOutbox.Bubble(
                bubbleID: bubbleID,
                content: "Same content",
                createdAt: Date(timeIntervalSince1970: 1_783_558_700 + Double(offset)),
                isFastModeEnabled: false,
                model: session.model,
                attempts: [
                    .init(attemptID: UUID(43 + offset * 2), state: .sending),
                ]
            )
        }
        let outbox = Shared(
            wrappedValue: initialOutbox,
            .inMemory("ambiguous-provisional-outbox-\(UUID())")
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(workspace: workspace, repository: nil),
                    outbox: outbox
                )
            ) {
                WorkspaceChat()
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            await store.send(.chat(.messagesUpdated([message])))

            #expect(store.state.messageIDToBubbleID[message.id] == nil)
            #expect(store.state.outbox[workspace.id, session.id].count == 2)
        }
    }
}

private struct RecordedSend: Equatable, Sendable {
    let message: String
    let model: Session.Model
    let isFastModeEnabled: Bool
    let attemptID: UUID
}

private struct FailingOutboxKey: SharedKey {
    let id = UUID()

    func load(
        context: LoadContext<MessageOutbox>,
        continuation: LoadContinuation<MessageOutbox>
    ) {
        continuation.resumeReturningInitialValue()
    }

    func subscribe(
        context: LoadContext<MessageOutbox>,
        subscriber: SharedSubscriber<MessageOutbox>
    ) -> SharedSubscription {
        SharedSubscription { }
    }

    func save(
        _ value: MessageOutbox,
        context: SaveContext,
        continuation: SaveContinuation
    ) {
        continuation.resume(throwing: OutboxTestError.saveFailed)
    }
}

private struct SuspendingOutboxKey: SharedKey {
    let id = UUID()
    let gate: OutboxSaveGate

    func load(
        context: LoadContext<MessageOutbox>,
        continuation: LoadContinuation<MessageOutbox>
    ) {
        continuation.resumeReturningInitialValue()
    }

    func subscribe(
        context: LoadContext<MessageOutbox>,
        subscriber: SharedSubscriber<MessageOutbox>
    ) -> SharedSubscription {
        SharedSubscription { }
    }

    func save(
        _ value: MessageOutbox,
        context: SaveContext,
        continuation: SaveContinuation
    ) {
        switch context {
        case .didSet:
            continuation.resume()
        case .userInitiated:
            gate.suspendFirst(continuation)
        }
    }
}

private final class OutboxSaveGate: @unchecked Sendable {
    private let continuation = LockIsolated<SaveContinuation?>(nil)
    private let hasSuspended = LockIsolated(false)
    private let suspensions: AsyncStream<Void>
    private let suspensionContinuation: AsyncStream<Void>.Continuation

    init() {
        (suspensions, suspensionContinuation) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    func suspendFirst(_ continuation: SaveContinuation) {
        let shouldSuspend = hasSuspended.withValue { hasSuspended in
            defer { hasSuspended = true }
            return !hasSuspended
        }
        if shouldSuspend {
            self.continuation.setValue(continuation)
            suspensionContinuation.yield()
        } else {
            continuation.resume()
        }
    }

    func waitUntilSuspended() async throws {
        let suspensions = suspensions
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in suspensions {
                    return
                }
                throw OutboxTestError.saveDidNotSuspend
            }
            group.addTask {
                try await ContinuousClock().sleep(for: .seconds(1))
                throw OutboxTestError.saveDidNotSuspend
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }

    func succeed() {
        continuation.withValue {
            $0?.resume()
            $0 = nil
        }
    }

    func fail() {
        continuation.withValue {
            $0?.resume(throwing: OutboxTestError.saveFailed)
            $0 = nil
        }
    }
}

private enum OutboxTestError: Error {
    case saveFailed
    case saveDidNotSuspend
}

private func makeSession(
    id: String,
    workspaceID: String,
    isHidden: Bool = false,
    createdAt: String = "2026-07-09 00:00:00",
    status: String = "idle",
    unreadCount: Int = 0,
    updatedAt: String = "2026-07-09 01:00:00"
) throws -> Session {
    try JSONDecoder().decode(
        Session.self,
        from: Data(
            """
            {
              "id": "\(id)",
              "workspace_id": "\(workspaceID)",
              "title": "Session \(id)",
              "agent_type": "claude",
              "is_hidden": \(isHidden),
              "created_at": "\(createdAt)",
              "updated_at": "\(updatedAt)",
              "status": "\(status)",
              "model": "sonnet",
              "unread_count": \(unreadCount),
              "freshly_compacted": 0,
              "context_token_count": 0
            }
            """.utf8
        )
    )
}

private func makeWorkspace(
    activeSessionID: String? = nil,
    branch: String? = nil,
    unread: Int = 0,
    status: Workspace.Status? = nil
) throws -> Workspace {
    let activeSession = activeSessionID.map { "\"\($0)\"" } ?? "null"
    let branch = branch.map { "\"\($0)\"" } ?? "null"
    let derivedStatus = status.map { "\"\($0.rawValue)\"" } ?? "null"
    return try JSONDecoder.conductor.decode(
        Workspace.self,
        from: Data(
            """
            {
              "id": "workspace-1",
              "active_session_id": \(activeSession),
              "branch": \(branch),
              "derived_status": \(derivedStatus),
              "created_at": "2026-07-09 00:00:00",
              "updated_at": "2026-07-09 00:00:00",
              "is_working": false,
              "unread": \(unread)
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
