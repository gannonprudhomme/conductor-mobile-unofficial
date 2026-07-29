//
//  ArchivedSessionsTests.swift
//  ConductorChatTests
//
//  Created by Gannon Prudomme on 7/24/26.
//

import ComposableArchitecture
import ConductorMobileData
import SharedConductorData
import SQLiteData
@testable import ConductorChat
import Testing

@MainActor
struct ArchivedSessionsTests {
    @Test("Archived sessions can be restored")
    func restoreArchivedSession() async throws {
        let session = Session.preview(
            id: "archived",
            workspaceID: "workspace",
            isHidden: true
        )
        let request = LockIsolated<(String, String)?>(nil)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { session }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: ArchivedSessions.State(
                    workspaceID: session.workspaceID,
                    sessions: [session],
                    activeSessions: []
                )
            ) {
                ArchivedSessions()
            } withDependencies: {
                $0.desktopClient.restoreSession = { workspaceID, sessionID in
                    request.setValue((workspaceID, sessionID))
                }
            }

            await store.send(.restoreSessionButtonTapped(session)) {
                $0.restoringSessionIDs = [session.id]
            }
            await store.receive(\.restoreSessionSucceeded) {
                $0.restoringSessionIDs = []
            }
            #expect(request.value?.0 == session.workspaceID)
            #expect(request.value?.1 == session.id)
        }
    }

    @Test("Five active sessions reject restore")
    func restoreAtTabLimit() async throws {
        let workspaceID = "workspace"
        let archivedSession = Session.preview(
            id: "archived",
            workspaceID: workspaceID,
            isHidden: true
        )
        let activeSessions = (1...5).map {
            Session.preview(id: "active-\($0)", workspaceID: workspaceID)
        }
        let requestCount = LockIsolated(0)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { activeSessions + [archivedSession] }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: ArchivedSessions.State(
                    workspaceID: workspaceID,
                    sessions: [archivedSession],
                    activeSessions: activeSessions
                )
            ) {
                ArchivedSessions()
            } withDependencies: {
                $0.desktopClient.restoreSession = { _, _ in
                    requestCount.withValue { $0 += 1 }
                }
            }

            await store.send(.restoreSessionButtonTapped(archivedSession)) {
                $0.alert = .maximumTabsReached
            }
            #expect(requestCount.value == 0)
        }
    }

    @Test("In-flight restores reserve capacity and ignore repeated taps")
    func inFlightRestoreCapacity() async throws {
        let workspaceID = "workspace"
        let archivedSessions = [
            Session.preview(id: "archived-1", workspaceID: workspaceID, isHidden: true),
            Session.preview(id: "archived-2", workspaceID: workspaceID, isHidden: true),
        ]
        let activeSessions = (1...4).map {
            Session.preview(id: "active-\($0)", workspaceID: workspaceID)
        }
        let requestCount = LockIsolated(0)
        let (responses, responseContinuation) = AsyncStream<Void>.makeStream()

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert { activeSessions + archivedSessions }.execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: ArchivedSessions.State(
                    workspaceID: workspaceID,
                    sessions: archivedSessions,
                    activeSessions: activeSessions
                )
            ) {
                ArchivedSessions()
            } withDependencies: {
                $0.desktopClient.restoreSession = { _, _ in
                    requestCount.withValue { $0 += 1 }
                    for await _ in responses {
                        return
                    }
                    throw CancellationError()
                }
            }

            await store.send(.restoreSessionButtonTapped(archivedSessions[0])) {
                $0.restoringSessionIDs = [archivedSessions[0].id]
            }
            await store.send(.restoreSessionButtonTapped(archivedSessions[0]))
            await store.send(.restoreSessionButtonTapped(archivedSessions[1])) {
                $0.alert = .maximumTabsReached
            }
            #expect(requestCount.value == 1)

            await store.send(.alert(.dismiss)) {
                $0.alert = nil
            }
            responseContinuation.yield(())
            await store.receive(\.restoreSessionSucceeded) {
                $0.restoringSessionIDs = []
            }
            responseContinuation.finish()
        }
    }

    @Test("Cloud history preserves API order and disables unavailable restore")
    func cloudHistoryIsSourceAware() async throws {
        let workspaceID = "workspace"
        let cloudActive = Session.preview(
            id: "canonical-active",
            workspaceID: workspaceID
        )
        let firstCloudArchived = Session.preview(
            id: "canonical-first",
            workspaceID: workspaceID,
            isHidden: true
        )
        let secondCloudArchived = Session.preview(
            id: "canonical-second",
            workspaceID: workspaceID,
            isHidden: true
        )
        let desktopSessions = (1...6).map {
            Session.preview(
                id: "desktop-\($0)",
                workspaceID: workspaceID,
                isHidden: $0 == 6
            )
        }
        let request = LockIsolated<(String, String)?>(nil)

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Session.upsert {
                    [cloudActive, firstCloudArchived, secondCloudArchived]
                        + desktopSessions
                }
                .execute(database)
                try CloudSessionMetadata.insert {
                    [
                        CloudSessionMetadata(
                            canonicalSessionID: cloudActive.id,
                            cloudSessionID: "remote-active",
                            workspaceID: workspaceID,
                            accountID: "account",
                            listOrder: 0,
                            refreshGeneration: "generation"
                        ),
                        CloudSessionMetadata(
                            canonicalSessionID: secondCloudArchived.id,
                            cloudSessionID: "remote-second",
                            workspaceID: workspaceID,
                            accountID: "account",
                            listOrder: 1,
                            refreshGeneration: "generation"
                        ),
                        CloudSessionMetadata(
                            canonicalSessionID: firstCloudArchived.id,
                            cloudSessionID: "remote-first",
                            workspaceID: workspaceID,
                            accountID: "account",
                            listOrder: 2,
                            refreshGeneration: "generation"
                        ),
                    ]
                }
                .execute(database)
            }
        } operation: {
            let store = TestStore(
                initialState: ArchivedSessions.State(
                    workspaceID: workspaceID,
                    source: .cloud,
                    sessions: [],
                    activeSessions: [],
                    mutationRoute: .cloud(
                        accountID: "account",
                        remoteWorkspaceID: workspaceID
                    )
                )
            ) {
                ArchivedSessions()
            } withDependencies: {
                $0.desktopClient.restoreSession = { workspaceID, sessionID in
                    request.setValue((workspaceID, sessionID))
                }
            }

            #expect(store.state.activeSessions.map(\.id) == [cloudActive.id])
            #expect(
                store.state.sessions.map(\.id)
                    == [secondCloudArchived.id, firstCloudArchived.id]
            )
            await store.send(.restoreSessionButtonTapped(secondCloudArchived))
            #expect(request.value == nil)
        }
    }
}
