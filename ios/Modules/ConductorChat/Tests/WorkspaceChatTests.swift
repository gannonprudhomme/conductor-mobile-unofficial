//
//  WorkspaceChatTests.swift
//  ConductorChatTests
//
//  Created by Gannon Prudomme on 7/11/26.
//

import ComposableArchitecture
import ConductorCloud
import ConductorMobileData
import Foundation
import SharedConductorData
import SQLiteData
@testable import ConductorChat
import Testing

@MainActor
struct WorkspaceChatTests {
    @Test("Only quiescent workspace chat presentation is warm-restorable")
    func warmPresentationRequiresQuiescence() throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)

        try withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Workspace.upsert { workspace }.execute(database)
                try Session.upsert { session }.execute(database)
            }
        } operation: {
            var idleState = WorkspaceChat.State(
                workspaceWithRepository: WorkspaceWithRepository(
                    workspace: workspace,
                    repository: nil
                )
            )
            idleState.isLoadingSessions = false
            idleState.chat?.isLoadingMessages = false
            #expect(idleState.canRestoreWarmPresentation)

            func expectNotRestorable(
                _ mutate: (inout WorkspaceChat.State) -> Void
            ) {
                var state = idleState
                mutate(&state)
                #expect(!state.canRestoreWarmPresentation)
            }

            expectNotRestorable { $0.isLoadingSessions = true }
            expectNotRestorable { $0.chat?.isLoadingMessages = true }
            expectNotRestorable {
                $0.chat?.optimisticMessages = [
                    WorkspaceChat.OptimisticMessage(
                        id: UUID(0),
                        workspaceID: workspace.id,
                        sessionID: session.id,
                        content: "Sending",
                        model: session.model,
                        isFastModeEnabled: false,
                        mode: .sent,
                        reasoningEffort: session.reasoningEffort,
                        status: .sending,
                        previousTurnID: nil
                    ),
                ]
            }
            expectNotRestorable { $0.chat?.isStopInFlight = true }
            expectNotRestorable { $0.isCreatingSession = true }
            expectNotRestorable { $0.isArchivingWorkspace = true }
            expectNotRestorable { $0.isClosingSession = true }
            expectNotRestorable { $0.isRenamingBranch = true }
            expectNotRestorable { $0.isRenamingSession = true }
            expectNotRestorable { $0.isWorkspaceMutationInFlight = true }
            expectNotRestorable { $0.sessionIDsBeforeCreation = [] }
            expectNotRestorable { $0.sessionIDAwaitingObservation = "pending" }
            expectNotRestorable { $0.renamingSession = session }
            expectNotRestorable { $0.destination = .renameBranch }
            expectNotRestorable {
                $0.chat?.queuedMessages.isEditStartInFlight = true
            }
            expectNotRestorable {
                $0.chat?.queuedMessages.editingMessageID = "editing"
            }
            expectNotRestorable {
                $0.chat?.queuedMessages.isEditInFlight = true
            }
            expectNotRestorable {
                $0.chat?.queuedMessages.messageActionInFlightID = "deleting"
            }
            expectNotRestorable {
                $0.chat?.queuedMessages.isReorderInFlight = true
            }
            expectNotRestorable {
                $0.chat?.queuedMessages.isResumeInFlight = true
            }
            expectNotRestorable {
                $0.chat?.queuedMessages.pendingMessageIDs = ["pending"]
            }
        }
    }

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

    @Test("Cached Cloud sessions remain visible during an offline retry")
    func cachedCloudSessionsRemainVisibleOffline() async throws {
        let workspace = Workspace.preview(
            id: "workspace",
            activeSessionID: "canonical-session",
            hostingServerURL: Workspace.conductorCloudHostingServerURL
        )
        let session = Session.preview(
            id: "canonical-session",
            workspaceID: workspace.id
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Workspace.upsert { workspace }.execute(database)
                try Session.upsert { session }.execute(database)
                try CloudSessionMetadata.insert {
                    CloudSessionMetadata(
                        canonicalSessionID: session.id,
                        cloudSessionID: "remote-session",
                        workspaceID: workspace.id,
                        accountID: "account",
                        listOrder: 0,
                        refreshGeneration: "generation"
                    )
                }
                .execute(database)
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

            #expect(!store.state.isLoadingSessions)
            #expect(store.state.chat?.sessionID == session.id)
            await store.send(
                .loadSessionsResponse(
                    .failure(URLError(.notConnectedToInternet))
                )
            )
            #expect(!store.state.isLoadingSessions)
            #expect(store.state.chat?.sessionID == session.id)
        }
    }

    @Test("Cloud session observation reconciles Desktop visibility")
    func cloudObservationReconcilesDesktopVisibility() async throws {
        let workspace = Workspace.preview(
            id: "workspace",
            hostingServerURL: Workspace.conductorCloudHostingServerURL
        )
        let activeDesktopSession = Session.preview(
            id: "active",
            workspaceID: workspace.id
        )
        let archivedDesktopSession = Session.preview(
            id: "archived",
            workspaceID: workspace.id,
            isHidden: true
        )
        let database = try appDatabase()
        try await database.write { database in
            try Workspace.upsert { workspace }.execute(database)
        }

        let (cloudStream, cloudContinuation) = AsyncThrowingStream<
            CloudWorkspaceSessionSnapshot,
            any Error
        >.makeStream()
        let (desktopStream, desktopContinuation) = AsyncThrowingStream<
            [Session],
            any Error
        >.makeStream()
        let cloudConnectionCount = LockIsolated(0)
        let desktopConnectionCount = LockIsolated(0)
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
            $0.defaultDatabase = database
            $0.cloudAPIClient.observeSessions = { workspaceID in
                #expect(workspaceID == workspace.id)
                cloudConnectionCount.withValue { $0 += 1 }
                return cloudStream
            }
            $0.desktopClient.observeSessions = { workspaceID in
                #expect(workspaceID == workspace.id)
                desktopConnectionCount.withValue { $0 += 1 }
                return desktopStream
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        let task = await store.send(.task)
        cloudContinuation.yield(
            cloudSessionSnapshot(
                workspaceID: workspace.id,
                sessionIDs: ["active", "archived"]
            )
        )
        desktopContinuation.yield(
            [activeDesktopSession, archivedDesktopSession]
        )

        for _ in 0..<1_000 {
            let counts = try await database.read { database in
                (
                    try CloudSessionMetadata
                        .sessions(
                            workspaceID: workspace.id,
                            isHidden: false
                        )
                        .fetchAll(database)
                        .count,
                    try CloudSessionMetadata
                        .sessions(
                            workspaceID: workspace.id,
                            isHidden: true
                        )
                        .fetchAll(database)
                        .count
                )
            }
            if counts.0 == 1, counts.1 == 1 {
                break
            }
            await Task.yield()
        }

        let visibleSessionIDs = try await database.read { database in
            try CloudSessionMetadata
                .sessions(workspaceID: workspace.id, isHidden: false)
                .fetchAll(database)
                .map(\.id)
        }
        #expect(
            visibleSessionIDs
                == [
                    CloudCanonicalID.session(
                        accountID: "account",
                        remoteSessionID: "active"
                    ),
                ]
        )
        #expect(cloudConnectionCount.value == 1)
        #expect(desktopConnectionCount.value == 1)

        await task.cancel()
        cloudContinuation.finish()
        desktopContinuation.finish()
    }

    @Test("Cloud sessions load without a Desktop connection")
    func cloudSessionsLoadWithoutDesktopConnection() async throws {
        let workspace = Workspace.preview(
            id: "workspace",
            hostingServerURL: Workspace.conductorCloudHostingServerURL
        )
        let database = try appDatabase()
        try await database.write { database in
            try Workspace.upsert { workspace }.execute(database)
        }
        let (cloudStream, cloudContinuation) = AsyncThrowingStream<
            CloudWorkspaceSessionSnapshot,
            any Error
        >.makeStream()
        let cloudConnectionCount = LockIsolated(0)
        let desktopConnectionCount = LockIsolated(0)
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
            $0.continuousClock = TestClock()
            $0.defaultDatabase = database
            $0.cloudAPIClient.observeSessions = { workspaceID in
                #expect(workspaceID == workspace.id)
                cloudConnectionCount.withValue { $0 += 1 }
                return cloudStream
            }
            $0.desktopClient.observeSessions = { workspaceID in
                #expect(workspaceID == workspace.id)
                desktopConnectionCount.withValue { $0 += 1 }
                return AsyncThrowingStream {
                    $0.finish(throwing: TestError())
                }
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        let task = await store.send(.task)
        cloudContinuation.yield(
            cloudSessionSnapshot(
                workspaceID: workspace.id,
                sessionIDs: ["cloud-only"]
            )
        )
        await store.receive(\.loadSessionsResponse.success)

        #expect(cloudConnectionCount.value == 1)
        #expect(desktopConnectionCount.value == 1)
        #expect(!store.state.isLoadingSessions)
        #expect(
            store.state.chat?.sessionID
                == CloudCanonicalID.session(
                    accountID: "account",
                    remoteSessionID: "cloud-only"
                )
        )
        #expect(store.state.destination == nil)

        await task.cancel()
        cloudContinuation.finish()
    }

    @Test("A same-account credential revision restarts session observation")
    func credentialRevisionRestartsSessionObservation() async throws {
        let workspace = Workspace.preview(
            id: "workspace",
            activeSessionID: "canonical-session",
            hostingServerURL: Workspace.conductorCloudHostingServerURL
        )
        let session = Session.preview(
            id: "canonical-session",
            workspaceID: workspace.id
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Workspace.upsert { workspace }.execute(database)
                try Session.upsert { session }.execute(database)
                try CloudSessionMetadata.insert {
                    CloudSessionMetadata(
                        canonicalSessionID: session.id,
                        cloudSessionID: "remote-session",
                        workspaceID: workspace.id,
                        accountID: "account",
                        listOrder: 0,
                        refreshGeneration: "generation"
                    )
                }
                .execute(database)
            }
        } operation: {
            @Shared(.cloudConfiguration) var cloudConfiguration
            $cloudConfiguration.withLock {
                $0 = CloudConfiguration(
                    accountID: "account",
                    credentialGeneration: UUID(1)
                )
            }
            let connectionCount = LockIsolated(0)
            let (stream, continuation) = AsyncThrowingStream<
                CloudWorkspaceSessionSnapshot,
                any Error
            >.makeStream()
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
                $0.continuousClock = TestClock()
                $0.cloudAPIClient.observeSessions = { _ in
                    connectionCount.withValue { $0 += 1 }
                    return stream
                }
                $0.desktopClient.observeSessions = { _ in
                    AsyncThrowingStream { _ in }
                }
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            let task = await store.send(.task)
            for _ in 0..<1_000 where connectionCount.value < 1 {
                await Task.yield()
            }
            $cloudConfiguration.withLock {
                $0 = CloudConfiguration(
                    accountID: "account",
                    credentialGeneration: UUID(2)
                )
            }
            await store.receive(\.cloudConfigurationChanged)
            for _ in 0..<1_000 where connectionCount.value < 2 {
                await Task.yield()
            }
            #expect(connectionCount.value == 2)

            await task.cancel()
            continuation.finish()
        }
    }

    @Test("A stale transcript failure cannot alert a replacement chat")
    func staleTranscriptFailureIsIgnored() async throws {
        let workspace = try makeWorkspace(activeSessionID: "current")
        let session = try makeSession(
            id: "current",
            workspaceID: workspace.id
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
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
                    .loadMessagesFailed(
                        sessionID: "replaced-session",
                        error: TestError()
                    )
                )
            )
            #expect(store.state.destination == nil)
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

    @Test("A mounted Desktop workspace rebuilds from Cloud-owned sessions")
    func mountedWorkspaceReclassifiesAsCloud() async throws {
        let workspace = try makeWorkspace(activeSessionID: "desktop")
        let desktopSession = try makeSession(
            id: "desktop",
            workspaceID: workspace.id
        )
        let cloudSession = try makeSession(
            id: "canonical-cloud",
            workspaceID: workspace.id
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Workspace.upsert { workspace }.execute(database)
                try Session.upsert { desktopSession }.execute(database)
            }
        } operation: {
            @Dependency(\.defaultDatabase) var database
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
                $0.continuousClock = TestClock()
                $0.cloudAPIClient.observeSessions = { _ in
                    AsyncThrowingStream { _ in }
                }
                $0.desktopClient.observeSessions = { _ in
                    AsyncThrowingStream { _ in }
                }
            }
            store.exhaustivity = .off(showSkippedAssertions: false)
            #expect(store.state.chat?.sessionID == desktopSession.id)
            await store.send(.archivedSessionsButtonTapped)
            #expect(store.state.destination != nil)

            try await database.write { database in
                try Session.upsert { cloudSession }.execute(database)
                try CloudSessionMetadata.insert {
                    CloudSessionMetadata(
                        canonicalSessionID: cloudSession.id,
                        cloudSessionID: "remote-cloud",
                        workspaceID: workspace.id,
                        accountID: "account",
                        listOrder: 0,
                        refreshGeneration: "generation"
                    )
                }
                .execute(database)
                try Workspace
                    .find(workspace.id)
                    .update {
                        $0.hostingServerURL =
                            #bind(Workspace.conductorCloudHostingServerURL)
                        $0.activeSessionID = #bind(cloudSession.id)
                    }
                    .execute(database)
            }

            for _ in 0..<1_000 where !store.state.workspace.isCloudHosted {
                await Task.yield()
            }
            #expect(store.state.workspace.isCloudHosted)
            let reload = await store.send(.hostingSourceChanged(.cloud))
            #expect(store.state.destination == nil)
            await store.receive(\.hostingSourceReloaded)
            #expect(store.state.activeSessions.map(\.id) == [cloudSession.id])
            #expect(store.state.chat?.sessionID == cloudSession.id)
            #expect(store.state.chat?.isCloudHosted == true)
            await reload.cancel()
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

            let task = await store.send(.task)

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

    @Test("Session rename is feature-owned, trimmed, and submitted")
    func sessionRename() async throws {
        let workspace = try makeWorkspace()
        let session = try makeSession(
            id: "session",
            workspaceID: workspace.id,
            title: "Old title"
        )
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
                $0.desktopClient.renameSession = { workspaceID, sessionID, title in
                    requests.withValue {
                        $0.append("\(workspaceID):\(sessionID):\(title)")
                    }
                }
            }

            await store.send(.renameSessionButtonTapped(session)) {
                $0.renamingSession = session
                $0.sessionTitleDraft = "Old title"
                $0.destination = .renameSession
            }
            await store.send(.binding(.set(\.sessionTitleDraft, "  New title  "))) {
                $0.sessionTitleDraft = "  New title  "
            }
            await store.send(.renameSessionSubmitted) {
                $0.isRenamingSession = true
                $0.renamingSession = nil
                $0.sessionTitleDraft = "New title"
                $0.destination = nil
            }
            await store.receive(\.renameSessionResponse) {
                $0.isRenamingSession = false
            }
            #expect(requests.value == ["\(workspace.id):\(session.id):New title"])
        }
    }

    @Test("Feature failures replace session rename presentation")
    func featureFailureReplacesSessionRename() async throws {
        let workspace = try makeWorkspace()
        let session = try makeSession(id: "session", workspaceID: workspace.id)

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

            await store.send(.renameSessionButtonTapped(session)) {
                $0.renamingSession = session
                $0.sessionTitleDraft = session.title ?? ""
                $0.destination = .renameSession
            }
            await store.send(.closeSessionResponse(.failure(TestError()))) {
                $0.destination = .alert(
                    .failedToCloseSession(message: TestError().localizedDescription)
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
                $0.uuid = .incrementing
                $0.desktopClient.sendMessage = {
                    workspaceID,
                    sessionID,
                    message,
                    model,
                    _,
                    mode,
                    _,
                    _ in
                    #expect(workspaceID == workspace.id)
                    #expect(sessionID == activeSession.id)
                    #expect(message == "Run the tests.")
                    #expect(model == activeSession.model)
                    #expect(mode == .sent)
                    for await _ in responses {
                        return .rejected(reason: TestError().localizedDescription)
                    }
                    return .unknown(reason: "The response stream ended.")
                }
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            let chat = try #require(store.state.chat)
            chat.$messageDraft.withLock { $0 = "Run the tests." }
            await store.send(.chat(.sendButtonTapped(.sent)))
            await store.send(.sessionButtonTapped(selectedSession)) {
                $0.hasUserSelectedSession = true
                $0.chat = Chat.State(session: selectedSession)
            }

            responseContinuation.yield()
            await store.receive(\.messageSendResponse)
            responseContinuation.finish()
            await store.finish()
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
                        sessions: [session],
                        activeSessions: [activeSession]
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

            await store.send(.workspacePinnedButtonTapped) {
                $0.isWorkspaceMutationInFlight = true
            }
            await store.receive(\.workspaceMutationFailed) {
                $0.isWorkspaceMutationInFlight = false
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

            await store.send(.workspacePinnedButtonTapped) {
                $0.isWorkspaceMutationInFlight = true
            }
            await store.receive(\.workspaceMutationUsedSQLiteFallback) {
                $0.isWorkspaceMutationInFlight = false
                $0.destination = .alert(.workspaceMutationUsedSQLiteFallback)
            }
        }
    }

    @Test("Concise transcripts are copied from the local message cache")
    func copyConciseTranscriptLocally() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)
        let messages = [
            Message(
                id: "user",
                sessionID: session.id,
                role: .user,
                content: "Summarize this",
                createdAt: .distantPast,
                turnID: "turn"
            ),
            Message(
                id: "assistant",
                sessionID: session.id,
                role: .assistant,
                content: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}"#,
                createdAt: .distantPast.addingTimeInterval(1),
                turnID: "turn"
            ),
        ]

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
                try Message.upsert { messages }.execute(database)
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

            await store.send(.copyConciseTranscriptButtonTapped(session))
            await store.receive(\.copyConciseTranscriptResponse.success) {
                $0.conciseTranscript = """
                    ## User

                    Summarize this

                    ## Assistant

                    Done.
                    """
                $0.transcriptCopyCount = 1
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

            await store.send(
                .chat(
                    .loadMessagesFailed(
                        sessionID: activeSession.id,
                        error: TestError()
                    )
                )
            ) {
                $0.destination = .alert(
                    .failedToLoadMessages(message: TestError().localizedDescription)
                )
            }
            await store.send(.destination(.dismiss)) {
                $0.destination = nil
            }
        }
    }

    @Test("When chat fails to send a message, an alert is presented and dismissed")
    func chatFailsToSendMessage() async throws {
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

            await store.send(
                .chat(
                    .sendMessageResponse(
                        sessionID: activeSession.id,
                        submittedDraft: "message",
                        result: .failure(TestError())
                    )
                )
            ) {
                $0.destination = .alert(
                    .failedToSendMessage(message: TestError().localizedDescription)
                )
            }
            await store.send(.destination(.dismiss)) {
                $0.destination = nil
            }
        }
    }

    @Test("When a queue reorder fails, an alert is presented and dismissed")
    func queueReorderFails() async throws {
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
            }

            await store.send(
                .chat(
                    .queuedMessages(
                        .reorderResponse(
                            sessionID: activeSession.id,
                            result: .failure(TestError())
                        )
                    )
                )
            ) {
                $0.destination = .alert(
                    .failedToReorderQueuedMessages(
                        message: TestError().localizedDescription
                    )
                )
            }
            await store.send(.destination(.dismiss)) {
                $0.destination = nil
            }
        }
    }

    @Test("When resuming a queue fails, an alert is presented and dismissed")
    func resumeQueueFails() async throws {
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
            }

            await store.send(
                .chat(
                    .queuedMessages(
                        .resumeResponse(
                            sessionID: activeSession.id,
                            result: .failure(TestError())
                        )
                    )
                )
            ) {
                $0.destination = .alert(
                    .failedToResumeQueue(message: TestError().localizedDescription)
                )
            }
            await store.send(.destination(.dismiss)) {
                $0.destination = nil
            }
        }
    }

    @Test("When a queued message action fails, an alert is presented")
    func queuedMessageActionFails() async throws {
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
            }

            await store.send(
                .chat(
                    .queuedMessages(
                        .deleteResponse(
                            sessionID: activeSession.id,
                            messageID: "message-1",
                            result: .failure(TestError())
                        )
                    )
                )
            ) {
                $0.destination = .alert(
                    .failedToDeleteQueuedMessage(
                        message: TestError().localizedDescription
                    )
                )
            }
            await store.send(.destination(.dismiss)) {
                $0.destination = nil
            }
            await store.send(
                .chat(
                    .queuedMessages(
                        .steerResponse(
                            sessionID: activeSession.id,
                            messageID: "message-1",
                            result: .failure(TestError())
                        )
                    )
                )
            ) {
                $0.destination = .alert(
                    .failedToSteerQueuedMessage(
                        message: TestError().localizedDescription
                    )
                )
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
            await store.send(
                .chat(
                    .loadMessagesFailed(
                        sessionID: activeSession.id,
                        error: error
                    )
                )
            )
            await store.send(
                .chat(
                    .sendMessageResponse(
                        sessionID: activeSession.id,
                        submittedDraft: "message",
                        result: .failure(error)
                    )
                )
            ) {
                $0.destination = .alert(
                    .failedToSendMessage(message: error.localizedDescription)
                )
            }
            await store.send(.destination(.dismiss)) {
                $0.destination = nil
            }
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

            let task = await store.send(.task)

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
    @Test("Cloud session observation uses the remote workspace ID")
    func cloudSessionObservationUsesRemoteWorkspaceID() async throws {
        let accountID = "account"
        let remoteWorkspaceID = "remote-workspace"
        let canonicalWorkspaceID = CloudCanonicalID.workspace(
            accountID: accountID,
            remoteWorkspaceID: remoteWorkspaceID
        )
        let workspace = try makeWorkspace(
            activeSessionID: nil,
            id: canonicalWorkspaceID
        )
        let metadata = CloudWorkspaceMetadata(
            workspaceID: canonicalWorkspaceID,
            accountID: accountID,
            remoteWorkspaceID: remoteWorkspaceID,
            lastSeenGeneration: "generation"
        )
        let (stream, continuation) = AsyncThrowingStream<
            CloudWorkspaceSessionSnapshot,
            any Error
        >.makeStream()
        let snapshot = CloudWorkspaceSessionSnapshot(
            accountID: accountID,
            workspace: CloudWorkspace(
                id: remoteWorkspaceID,
                name: "Cloud workspace",
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            sessions: [],
            statuses: [:]
        )

        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Workspace.insert { workspace }.execute(db)
                try CloudWorkspaceMetadata.insert { metadata }.execute(db)
            }
        } operation: {
            @Shared(.cloudConfiguration) var cloudConfiguration
            $cloudConfiguration.withLock {
                $0 = CloudConfiguration(accountID: accountID)
            }
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: nil,
                        cloudMetadata: metadata
                    )
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.cloudAPIClient.observeSessions = { workspaceID in
                    #expect(workspaceID == remoteWorkspaceID)
                    return stream
                }
                $0.desktopClient.observeSessions = { workspaceID in
                    #expect(workspaceID == remoteWorkspaceID)
                    return AsyncThrowingStream { _ in }
                }
            }

            let task = await store.send(.task)
            await store.receive(\.mutationOutcomesUpdated)
            continuation.yield(snapshot)
            await store.receive(\.loadSessionsResponse.success) {
                $0.isLoadingSessions = false
            }
            await store.receive(\.sessionSnapshotPersisted) {
                $0.hasPersistedInitialSessionSnapshot = true
            }
            continuation.finish()
            await task.cancel()
        }
    }

    @Test("Send immediately inserts a bubble, clears the draft, scrolls, then hides progress")
    func optimisticSendAndAcceptance() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)
        let (responses, responseContinuation) = AsyncStream<Void>.makeStream()

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.uuid = .incrementing
                $0.desktopClient.sendMessage = { _, _, _, _, _, _, _, _ in
                    for await _ in responses {
                        return .accepted(messageID: "canonical")
                    }
                    return .unknown(reason: "The response stream ended.")
                }
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            let chat = try #require(store.state.chat)
            chat.$messageDraft.withLock { $0 = "  Run the tests.  " }
            await store.send(.chat(.sendButtonTapped(.sent)))

            #expect(store.state.chat?.messageDraft.isEmpty == true)
            #expect(store.state.chat?.scrollToBottomRequest == 1)
            #expect(
                store.state.optimisticMessagesBySession[session.id] == [
                    .init(
                        id: UUID(0),
                        workspaceID: workspace.id,
                        sessionID: session.id,
                        content: "Run the tests.",
                        model: session.model,
                        isFastModeEnabled: false,
                        mode: .sent,
                        reasoningEffort: .high,
                        status: .sending,
                        previousTurnID: nil
                    ),
                ]
            )
            #expect(store.state.chat?.rows?.last?.id == "human:\(UUID(0).uuidString)")

            responseContinuation.yield()
            responseContinuation.finish()
            await store.receive(\.messageSendResponse)
            await store.finish()

            #expect(
                store.state.optimisticMessagesBySession[session.id]?.first?.status
                    == .acceptedAwaitingObservation
            )
            #expect(store.state.chat?.isMessageSendInFlight == false)
            #expect(store.state.chat?.rows?.last?.id == "human:\(UUID(0).uuidString)")
        }
    }

    @Test("Cloud sends use the remote session ID")
    func cloudSendUsesRemoteSessionID() async throws {
        let workspace = Workspace.preview(
            id: "workspace",
            activeSessionID: "canonical-session",
            hostingServerURL: Workspace.conductorCloudHostingServerURL
        )
        let session = Session.preview(
            id: "canonical-session",
            workspaceID: workspace.id
        )
        let receivedSessionID = LockIsolated<String?>(nil)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Workspace.upsert { workspace }.execute(database)
                try Session.upsert { session }.execute(database)
                try CloudSessionMetadata.insert {
                    CloudSessionMetadata(
                        canonicalSessionID: session.id,
                        cloudSessionID: "remote-session",
                        workspaceID: workspace.id,
                        accountID: "account",
                        listOrder: 0,
                        refreshGeneration: "generation"
                    )
                }
                .execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.uuid = .incrementing
                $0.desktopClient.sendMessage = {
                    workspaceID,
                    sessionID,
                    _,
                    _,
                    _,
                    _,
                    _,
                    _ in
                    #expect(workspaceID == workspace.id)
                    receivedSessionID.setValue(sessionID)
                    return .rejected(reason: "No.")
                }
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            let chat = try #require(store.state.chat)
            #expect(chat.isCloudHosted)
            chat.$messageDraft.withLock { $0 = "Test" }
            await store.send(.chat(.sendButtonTapped(.sent)))
            await store.receive(\.messageSendResponse)
            await store.finish()

            #expect(receivedSessionID.value == "remote-session")
        }
    }

    @Test("A definite rejection retains the failed bubble")
    func rejectedSend() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.uuid = .incrementing
                $0.desktopClient.sendMessage = { _, _, _, _, _, _, _, _ in
                    .rejected(reason: "No.")
                }
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            let chat = try #require(store.state.chat)
            chat.$messageDraft.withLock { $0 = "Test" }
            await store.send(.chat(.sendButtonTapped(.sent)))
            await store.receive(\.messageSendResponse)
            await store.finish()

            #expect(
                store.state.optimisticMessagesBySession[session.id]?.first?.status
                    == .rejected
            )
            #expect(
                store.state.optimisticMessagesBySession[session.id]?.first?.deliveryDetail
                    == "No."
            )
            #expect(store.state.chat?.rows?.count == 1)
        }
    }

    @Test("Transport ambiguity is unconfirmed rather than rejected")
    func unconfirmedSend() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)
        let unrelatedMessage = Message(
            id: "unrelated",
            sessionID: session.id,
            role: .user,
            content: "Test",
            createdAt: Date(timeIntervalSince1970: 1_783_558_800),
            turnID: "desktop-turn"
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.uuid = .incrementing
                $0.desktopClient.sendMessage = { _, _, _, _, _, _, _, _ in
                    .unknown(reason: "Timed out.")
                }
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            let chat = try #require(store.state.chat)
            chat.$messageDraft.withLock { $0 = "Test" }
            await store.send(.chat(.sendButtonTapped(.sent)))
            await store.receive(\.messageSendResponse)
            await store.finish()

            #expect(
                store.state.optimisticMessagesBySession[session.id]?.first?.status
                    == .unconfirmed
            )
            #expect(
                store.state.optimisticMessagesBySession[session.id]?.first?.deliveryDetail
                    == "Timed out."
            )

            await store.send(.chat(.messagesUpdated([unrelatedMessage])))

            #expect(store.state.messageIDToBubbleID[unrelatedMessage.id] == nil)
            #expect(
                store.state.optimisticMessagesBySession[session.id]?.first?.status
                    == .unconfirmed
            )
            #expect(store.state.chat?.rows?.count == 2)
        }
    }

    @Test("An unrelated desktop message remains visible during a mobile send")
    func unrelatedDesktopMessageRemainsVisibleDuringSend() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)
        let desktopMessage = Message(
            id: "desktop",
            sessionID: session.id,
            role: .user,
            content: "Sent from the Mac",
            createdAt: Date(timeIntervalSince1970: 1_783_558_800),
            turnID: "desktop-turn"
        )
        let (responses, responseContinuation) = AsyncStream<Void>.makeStream()

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.uuid = .incrementing
                $0.desktopClient.sendMessage = { _, _, _, _, _, _, _, _ in
                    for await _ in responses {
                        return .accepted(messageID: "canonical")
                    }
                    return .unknown(reason: "The response stream ended.")
                }
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            let chat = try #require(store.state.chat)
            chat.$messageDraft.withLock { $0 = "Mobile message" }
            await store.send(.chat(.sendButtonTapped(.sent)))
            let optimisticRowID = try #require(store.state.chat?.rows?.last?.id)

            await store.send(.chat(.messagesUpdated([desktopMessage])))

            #expect(store.state.messageIDToBubbleID[desktopMessage.id] == nil)
            #expect(
                store.state.chat?.rows?.map(\.id)
                    == [optimisticRowID, "human:\(desktopMessage.id)"]
            )

            responseContinuation.finish()
            await store.receive(\.messageSendResponse)
            await store.finish()
        }
    }

    @Test("A queued send clears its original draft after switching sessions")
    func queuedSendClearsOriginalDraftAfterSessionSwitch() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let activeSession = try makeSession(id: "active", workspaceID: workspace.id)
        let selectedSession = try makeSession(id: "selected", workspaceID: workspace.id)
        let (responses, responseContinuation) =
            AsyncStream<MessageDeliveryResult>.makeStream()

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { [activeSession, selectedSession] }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.uuid = .incrementing
                $0.desktopClient.sendMessage = { _, _, _, _, _, _, _, _ in
                    for await result in responses {
                        return result
                    }
                    return .unknown(reason: "The response stream ended.")
                }
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            let chat = try #require(store.state.chat)
            chat.$messageDraft.withLock { $0 = "Queue this" }
            await store.send(.chat(.sendButtonTapped(.queued)))
            await store.send(.sessionButtonTapped(selectedSession))

            responseContinuation.yield(.accepted(messageID: nil))
            responseContinuation.finish()
            await store.receive(\.messageSendResponse)
            await store.finish()

            await store.send(.sessionButtonTapped(activeSession))
            #expect(store.state.chat?.messageDraft.isEmpty == true)
        }
    }

    @Test(
        "Queued rejection and uncertainty remain distinct after switching sessions",
        arguments: [
            MessageDeliveryResult.rejected(reason: "Queue rejected."),
            .unknown(reason: "Queue result lost."),
        ]
    )
    func queuedFailureAfterSessionSwitch(
        result: MessageDeliveryResult
    ) async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let activeSession = try makeSession(id: "active", workspaceID: workspace.id)
        let selectedSession = try makeSession(id: "selected", workspaceID: workspace.id)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { [activeSession, selectedSession] }.execute(database)
            }
        } operation: {
            var state = WorkspaceChat.State(
                workspaceWithRepository: .init(workspace: workspace, repository: nil)
            )
            let optimisticMessage = WorkspaceChat.OptimisticMessage(
                id: UUID(0),
                workspaceID: workspace.id,
                sessionID: activeSession.id,
                content: "Queue this",
                model: activeSession.model,
                isFastModeEnabled: false,
                mode: .queued,
                reasoningEffort: nil,
                status: .sending,
                previousTurnID: nil
            )
            state.optimisticMessagesBySession[activeSession.id] = [optimisticMessage]
            state.chat = Chat.State(session: selectedSession)
            let store = TestStore(initialState: state) {
                WorkspaceChat()
            }

            await store.send(
                .messageSendResponse(
                    .init(
                        workspaceID: workspace.id,
                        sessionID: activeSession.id,
                        messageID: optimisticMessage.id
                    ),
                    result
                )
            ) {
                $0.optimisticMessagesBySession[activeSession.id] = nil
                switch result {
                case .rejected(let reason):
                    $0.destination = .alert(.failedToQueueMessage(message: reason))
                case .unknown(let reason):
                    $0.destination = .alert(.messageQueueUnconfirmed(message: reason))
                case .accepted:
                    Issue.record("This test requires a failed delivery result")
                }
            }
        }
    }

    @Test("Canonical ID reconciliation preserves one display row")
    func canonicalIDReconciliation() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)
        let message = Message(
            id: "canonical",
            sessionID: session.id,
            role: .user,
            content: "Test",
            createdAt: Date(timeIntervalSince1970: 1_783_558_800),
            turnID: "canonical-turn"
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.uuid = .incrementing
                $0.desktopClient.sendMessage = { _, _, _, _, _, _, _, _ in
                    .accepted(messageID: message.id)
                }
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            let chat = try #require(store.state.chat)
            chat.$messageDraft.withLock { $0 = "Test" }
            await store.send(.chat(.sendButtonTapped(.sent)))
            await store.receive(\.messageSendResponse)
            await store.finish()
            let optimisticRowID = try #require(store.state.chat?.rows?.last?.id)

            await store.send(.chat(.messagesUpdated([message])))

            #expect(store.state.optimisticMessagesBySession[session.id] == nil)
            #expect(store.state.messageIDToBubbleID[message.id] == UUID(0))
            #expect(store.state.chat?.rows?.map(\.id) == [optimisticRowID])
            guard let row = store.state.chat?.rows?.first,
                  case .humanMessage = row.content else {
                Issue.record("Expected the canonical human row")
                return
            }
        }
    }

    @Test("Identical desktop text cannot claim a pending mobile bubble")
    func identicalDesktopMessageDoesNotReconcilePendingMobileMessage() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)
        let previousMessage = Message(
            id: "previous",
            sessionID: session.id,
            role: .user,
            content: "Previous",
            createdAt: Date(timeIntervalSince1970: 1_783_558_700),
            turnID: "previous-turn"
        )
        let desktopMessage = Message(
            id: "desktop",
            sessionID: session.id,
            role: .user,
            content: "Test",
            createdAt: Date(timeIntervalSince1970: 1_783_558_800),
            turnID: "desktop-turn"
        )
        let mobileMessage = Message(
            id: "mobile",
            sessionID: session.id,
            role: .user,
            content: "Test",
            createdAt: Date(timeIntervalSince1970: 1_783_558_900),
            turnID: "mobile-turn"
        )
        let (responses, responseContinuation) = AsyncStream<Void>.makeStream()

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.uuid = .incrementing
                $0.desktopClient.sendMessage = { _, _, _, _, _, _, _, _ in
                    for await _ in responses {
                        return .accepted(messageID: mobileMessage.id)
                    }
                    return .unknown(reason: "The response stream ended.")
                }
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            await store.send(
                .chat(
                    .initialMessagesResponse(
                        sessionID: session.id,
                        messages: [previousMessage]
                    )
                )
            )
            let chat = try #require(store.state.chat)
            chat.$messageDraft.withLock { $0 = "Test" }
            await store.send(.chat(.sendButtonTapped(.sent)))
            let optimisticRowID = try #require(store.state.chat?.rows?.last?.id)

            await store.send(
                .chat(.messagesUpdated([previousMessage, desktopMessage]))
            )

            #expect(store.state.optimisticMessagesBySession[session.id]?.count == 1)
            #expect(store.state.messageIDToBubbleID[desktopMessage.id] == nil)
            #expect(store.state.chat?.rows?.count == 3)
            #expect(store.state.chat?.rows?.contains { $0.id == optimisticRowID } == true)
            #expect(
                store.state.chat?.rows?.contains {
                    $0.id == "human:\(desktopMessage.id)"
                } == true
            )

            responseContinuation.yield()
            responseContinuation.finish()
            await store.receive(\.messageSendResponse)
            await store.finish()

            #expect(store.state.optimisticMessagesBySession[session.id]?.count == 1)
            #expect(store.state.messageIDToBubbleID[desktopMessage.id] == nil)

            await store.send(
                .chat(
                    .messagesUpdated([
                        previousMessage,
                        desktopMessage,
                        mobileMessage,
                    ])
                )
            )

            #expect(store.state.optimisticMessagesBySession[session.id] == nil)
            #expect(store.state.messageIDToBubbleID[desktopMessage.id] == nil)
            #expect(store.state.messageIDToBubbleID[mobileMessage.id] == UUID(0))
            #expect(store.state.chat?.rows?.count == 3)
            #expect(store.state.chat?.rows?.contains { $0.id == optimisticRowID } == true)
            #expect(
                store.state.chat?.rows?.contains {
                    $0.id == "human:\(desktopMessage.id)"
                } == true
            )
        }
    }

    @Test("Matching turn ID reconciles after a lost response")
    func turnIDReconciliation() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)
        let message = Message(
            id: "canonical",
            sessionID: session.id,
            role: .user,
            content: "Test",
            createdAt: Date(timeIntervalSince1970: 1_783_558_800),
            turnID: UUID(0).uuidString
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.uuid = .incrementing
                $0.desktopClient.sendMessage = { _, _, _, _, _, _, _, _ in
                    .unknown(reason: "Connection lost.")
                }
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            let chat = try #require(store.state.chat)
            chat.$messageDraft.withLock { $0 = "Test" }
            await store.send(.chat(.sendButtonTapped(.sent)))
            await store.receive(\.messageSendResponse)
            await store.finish()
            await store.send(.chat(.messagesUpdated([message])))

            #expect(store.state.optimisticMessagesBySession[session.id] == nil)
            #expect(store.state.messageIDToBubbleID[message.id] == UUID(0))
            #expect(store.state.chat?.rows?.count == 1)
        }
    }

    @Test("A failed message does not block a subsequent send")
    func failureDoesNotBlockSending() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)
        let secondMessage = Message(
            id: "second",
            sessionID: session.id,
            role: .user,
            content: "Second",
            createdAt: Date(timeIntervalSince1970: 1_783_558_800),
            turnID: "second-turn"
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: .init(
                        workspace: workspace,
                        repository: nil
                    )
                )
            ) {
                WorkspaceChat()
            } withDependencies: {
                $0.uuid = .incrementing
                $0.desktopClient.sendMessage = { _, _, message, _, _, _, _, _ in
                    if message == "First" {
                        .rejected(reason: "No.")
                    } else {
                        .accepted(messageID: "second")
                    }
                }
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            let chat = try #require(store.state.chat)
            chat.$messageDraft.withLock { $0 = "First" }
            await store.send(.chat(.sendButtonTapped(.sent)))
            await store.receive(\.messageSendResponse)
            await store.finish()

            let selectedChat = try #require(store.state.chat)
            selectedChat.$messageDraft.withLock { $0 = "Second" }
            await store.send(.chat(.sendButtonTapped(.sent)))
            await store.receive(\.messageSendResponse)
            await store.finish()

            #expect(
                store.state.optimisticMessagesBySession[session.id]?.map(\.status)
                    == [.rejected, .acceptedAwaitingObservation]
            )

            await store.send(.chat(.messagesUpdated([secondMessage])))

            #expect(
                store.state.chat?.rows?.map(\.id)
                    == [
                        "human:\(UUID(0).uuidString)",
                        "human:\(UUID(1).uuidString)",
                    ]
            )
            guard case .optimisticMessage =
                    store.state.chat?.rows?.first?.content,
                  case .humanMessage =
                    store.state.chat?.rows?.last?.content else {
                Issue.record("Expected failed A to remain before canonical B")
                return
            }
        }
    }

}

private func makeSession(
    id: String,
    workspaceID: String,
    isHidden: Bool = false,
    createdAt: String = "2026-07-09 00:00:00",
    status: String = "idle",
    title: String? = nil,
    unreadCount: Int = 0,
    updatedAt: String = "2026-07-09 01:00:00"
) throws -> Session {
    let title = title ?? "Session \(id)"
    return try JSONDecoder().decode(
        Session.self,
        from: Data(
            """
            {
              "id": "\(id)",
              "workspace_id": "\(workspaceID)",
              "title": "\(title)",
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

private func cloudSessionSnapshot(
    workspaceID: String,
    sessionIDs: [String]
) -> CloudWorkspaceSessionSnapshot {
    let date = Date(timeIntervalSince1970: 100)
    return CloudWorkspaceSessionSnapshot(
        accountID: "account",
        workspace: CloudWorkspace(
            id: workspaceID,
            name: "Cloud workspace",
            createdAt: date
        ),
        sessions: sessionIDs.map { sessionID in
            CloudSession(
                id: sessionID,
                deepLink: URL(string: "https://app.conductor.build")!,
                name: sessionID
            )
        },
        statuses: [:]
    )
}

private func makeWorkspace(
    activeSessionID: String? = nil,
    branch: String? = nil,
    id: String = "workspace-1",
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
              "id": "\(id)",
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
