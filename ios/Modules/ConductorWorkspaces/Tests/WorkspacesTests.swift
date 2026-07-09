import ComposableArchitecture
import ConductorData
import Foundation
@testable import ConductorWorkspaces
import Testing

@MainActor
struct WorkspacesTests {
    @Test("When refresh fails to load workspaces, an alert is presented")
    func refreshFailsToLoadWorkspaces() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let store = TestStore(initialState: Workspaces.State()) {
                Workspaces()
            } withDependencies: {
                $0.desktopClient.fetchWorkspaces = {
                    throw TestError()
                }
            }

            await store.send(.refresh)

            await store.receive(\.loadWorkspacesFailed) {
                $0.alert = .failedToLoadWorkspaces(message: TestError().localizedDescription)
            }
        }
    }

    @Test("When task fails to load workspaces, an alert is presented")
    func taskFailsToLoadWorkspaces() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let store = TestStore(initialState: Workspaces.State()) {
                Workspaces()
            } withDependencies: {
                $0.desktopClient.fetchWorkspaces = {
                    throw TestError()
                }
            }

            await store.send(.task)

            await store.receive(\.loadWorkspacesFailed) {
                $0.alert = .failedToLoadWorkspaces(message: TestError().localizedDescription)
            }
        }
    }
}

private struct TestError: LocalizedError {
    var errorDescription: String? {
        "Something went wrong."
    }
}
