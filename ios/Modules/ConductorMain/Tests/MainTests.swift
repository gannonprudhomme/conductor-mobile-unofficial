import ComposableArchitecture
import ConductorData
@testable import ConductorMain
import ConductorSessions
import Testing

@MainActor
struct MainTests {
    @Test("Selecting a workspace pushes its sessions list")
    func workspaceSelectionPushesSessionsList() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let workspace = Workspace.preview(branch: "add-sessions-screen")
            let store = TestStore(initialState: Main.State()) {
                Main()
            }

            await store.send(.workspaces(.workspaceTapped(workspace))) {
                $0.path.append(.sessions(SessionsList.State(workspace: workspace)))
            }
        }
    }
}
