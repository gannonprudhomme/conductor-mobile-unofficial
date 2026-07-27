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
}
