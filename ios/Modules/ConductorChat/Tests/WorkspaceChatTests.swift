//
//  WorkspaceChatTests.swift
//  ConductorChatTests
//
//  Created by Gannon Prudomme on 7/11/26.
//

import ComposableArchitecture
import ConductorData
import Foundation
import SQLiteData
@testable import ConductorChat
import Testing

@MainActor
struct WorkspaceChatTests {
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

            await store.send(.loadSessionsResponse(.success([cachedFallback, activeSession]))) {
                $0.shouldPreferRemoteActiveSession = false
                $0.chat = Chat.State(session: activeSession)
            }
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
                $0.shouldPreferRemoteActiveSession = false
            }
            await store.send(.loadSessionsResponse(.success([activeSession, cachedFallback])))
        }
    }

    @Test("Later polls preserve a valid selection")
    func laterPollsPreserveValidSelection() async throws {
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
                $0.shouldPreferRemoteActiveSession = false
            }
            await store.send(.sessionButtonTapped(selectedSession)) {
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
                $0.shouldPreferRemoteActiveSession = false
            }
            await store.send(.sessionButtonTapped(selectedSession)) {
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

    @Test("Sessions poll every second")
    func sessionsPollEverySecond() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let session = try makeSession(id: "active", workspaceID: workspace.id)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Session.upsert { session }.execute(db)
            }
        } operation: {
            let clock = TestClock()
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
                $0.desktopClient.fetchSessions = { workspaceID in
                    #expect(workspaceID == workspace.id)
                    return [session]
                }
            }

            let task = await store.send(.task)

            await store.receive(\.loadSessionsResponse.success) {
                $0.shouldPreferRemoteActiveSession = false
            }

            await clock.advance(by: .seconds(1))
            await store.receive(\.loadSessionsResponse.success)

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
                $0.shouldPreferRemoteActiveSession = false
            }
            await store.send(.sessionButtonTapped(selectedSession)) {
                $0.chat = Chat.State(session: selectedSession)
            }
            await store.send(.loadSessionsResponse(.success([activeSession, selectedSession])))
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

    @Test("When refresh fails to load sessions, an alert is presented")
    func refreshFailsToLoadSessions() async throws {
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
            } withDependencies: {
                $0.desktopClient.fetchSessions = { workspaceID in
                    #expect(workspaceID == workspace.id)
                    throw TestError()
                }
            }

            await store.send(.refresh)

            await store.receive(\.loadSessionsResponse.failure) {
                $0.destination = .alert(
                    .failedToLoadSessions(message: TestError().localizedDescription)
                )
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

            await store.send(.chat(.loadMessagesFailed("The service is unavailable."))) {
                $0.destination = .alert(
                    .failedToLoadMessages(message: "The service is unavailable.")
                )
            }
            await store.send(.destination(.dismiss)) {
                $0.destination = nil
            }
        }
    }

    @Test("When task fails to load sessions, an alert is presented")
    func taskFailsToLoadSessions() async throws {
        let workspace = try makeWorkspace(activeSessionID: "active")
        let activeSession = try makeSession(id: "active", workspaceID: workspace.id)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Session.upsert { activeSession }.execute(db)
            }
        } operation: {
            let clock = TestClock()
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
                $0.desktopClient.fetchSessions = { workspaceID in
                    #expect(workspaceID == workspace.id)
                    throw TestError()
                }
            }

            let task = await store.send(.task)

            await store.receive(\.loadSessionsResponse.failure) {
                $0.destination = .alert(
                    .failedToLoadSessions(message: TestError().localizedDescription)
                )
            }

            await task.cancel()
        }
    }
}

private func makeSession(
    id: String,
    workspaceID: String,
    isHidden: Bool = false,
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
              "created_at": "2026-07-09 00:00:00",
              "updated_at": "\(updatedAt)",
              "status": "idle",
              "model": "sonnet",
              "unread_count": 0,
              "freshly_compacted": 0,
              "context_token_count": 0
            }
            """.utf8
        )
    )
}

private func makeWorkspace(activeSessionID: String? = nil) throws -> Workspace {
    let activeSession = activeSessionID.map { "\"\($0)\"" } ?? "null"
    return try JSONDecoder.conductor.decode(
        Workspace.self,
        from: Data(
            """
            {
              "id": "workspace-1",
              "active_session_id": \(activeSession),
              "created_at": "2026-07-09 00:00:00",
              "updated_at": "2026-07-09 00:00:00",
              "is_working": false
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
