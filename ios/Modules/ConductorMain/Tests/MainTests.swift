import ComposableArchitecture
import ConductorChat
import ConductorData
@testable import ConductorMain
import ConductorSessions
import Foundation
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

    @Test("Selecting a session pushes its chat")
    func sessionSelectionPushesChat() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let workspace = Workspace.preview(branch: "add-chat-screen")
            let session = try makeSession(workspaceID: workspace.id)
            let store = TestStore(initialState: Main.State()) {
                Main()
            }

            await store.send(.workspaces(.workspaceTapped(workspace))) {
                $0.path.append(.sessions(SessionsList.State(workspace: workspace)))
            }
            await store.send(
                .path(
                    .element(
                        id: store.state.path.ids[0],
                        action: .sessions(.sessionTapped(session))
                    )
                )
            ) {
                $0.path.append(.chat(Chat.State(session: session)))
            }
        }
    }
}

private func makeSession(workspaceID: String) throws -> Session {
    try JSONDecoder().decode(
        Session.self,
        from: Data(
            """
            {
              "id": "session-1",
              "workspace_id": "\(workspaceID)",
              "title": "Chat",
              "agent_type": "codex",
              "created_at": "2026-07-09 00:00:00",
              "updated_at": "2026-07-09 00:00:00",
              "status": "idle",
              "model": "gpt-5",
              "unread_count": 0,
              "freshly_compacted": 0,
              "context_token_count": 0
            }
            """.utf8
        )
    )
}
