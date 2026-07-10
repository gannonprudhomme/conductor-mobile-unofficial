import ComposableArchitecture
import ConductorData
import Foundation
@testable import ConductorWorkspaces
import Testing

@MainActor
struct WorkspacesTests {
    @Test("Workspace filters persist between state instances")
    func filtersPersist() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let store = TestStore(initialState: Workspaces.State()) {
                Workspaces()
            }

            await store.send(.repositoryFilterButtonTapped("repo-1")) {
                $0.$selectedRepositoryID.withLock { $0 = "repo-1" }
            }
            await store.send(.sortButtonTapped(.created)) {
                $0.$sort.withLock { $0 = .created }
            }

            let restoredState = Workspaces.State()
            #expect(restoredState.selectedRepositoryID == "repo-1")
            #expect(restoredState.sort == .created)
        }
    }

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
                $0.desktopClient.fetchRepositories = { [] }
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
                $0.desktopClient.fetchRepositories = { [] }
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
