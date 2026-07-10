import ComposableArchitecture
import ConductorData
import Foundation
@testable import ConductorSessions
import Testing

@MainActor
struct SessionsListTests {
    @Test("Sessions poll every second and a successful initial load reveals the empty state")
    func sessionsPollEverySecond() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let clock = TestClock()
            let workspace = try makeWorkspace()
            let store = TestStore(initialState: SessionsList.State(workspace: workspace)) {
                SessionsList()
            } withDependencies: {
                $0.continuousClock = clock
                $0.desktopClient.fetchSessions = { workspaceID in
                    #expect(workspaceID == workspace.id)
                    return []
                }
            }

            let task = await store.send(.task)

            await store.receive(\.loadSessionsSucceeded) {
                $0.hasLoadedSessions = true
            }

            await clock.advance(by: .seconds(1))
            await store.receive(\.loadSessionsSucceeded)

            await task.cancel()
        }
    }

    @Test("When refresh fails to load sessions, an alert is presented")
    func refreshFailsToLoadSessions() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let workspace = try makeWorkspace()
            let store = TestStore(initialState: SessionsList.State(workspace: workspace)) {
                SessionsList()
            } withDependencies: {
                $0.desktopClient.fetchSessions = { workspaceID in
                    #expect(workspaceID == workspace.id)
                    throw TestError()
                }
            }

            await store.send(.refresh)

            await store.receive(\.loadSessionsFailed) {
                $0.alert = .failedToLoadSessions(message: TestError().localizedDescription)
            }
        }
    }

    @Test("When task fails to load sessions, an alert is presented")
    func taskFailsToLoadSessions() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let clock = TestClock()
            let workspace = try makeWorkspace()
            let store = TestStore(initialState: SessionsList.State(workspace: workspace)) {
                SessionsList()
            } withDependencies: {
                $0.continuousClock = clock
                $0.desktopClient.fetchSessions = { workspaceID in
                    #expect(workspaceID == workspace.id)
                    throw TestError()
                }
            }

            let task = await store.send(.task)

            await store.receive(\.loadSessionsFailed) {
                $0.alert = .failedToLoadSessions(message: TestError().localizedDescription)
            }

            await task.cancel()
        }
    }
}

private func makeWorkspace() throws -> Workspace {
    try JSONDecoder.conductor.decode(
        Workspace.self,
        from: Data(
            """
            {
              "id": "workspace-1",
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
