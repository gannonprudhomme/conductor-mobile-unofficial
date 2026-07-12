//
//  MainTests.swift
//  ConductorMainTests
//
//  Created by Gannon Prudomme on 7/11/26.
//

import ComposableArchitecture
import ConductorChat
import ConductorData
import ConductorWorkspaces
import SQLiteData
@testable import ConductorMain
import Testing

@MainActor
struct MainTests {
    @Test("Workspace selection pushes its chat")
    func workspaceSelectionPushesChat() async throws {
        let workspace = Workspace.preview(
            activeSessionID: "active",
            branch: "add-chat-screen"
        )
        let repository = Repository.preview()
        let item = WorkspaceWithRepository(workspace: workspace, repository: repository)

        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let store = TestStore(initialState: Main.State()) {
                Main()
            }

            await store.send(.workspaces(.workspaceTapped(item))) {
                $0.path.append(
                    .workspaceChat(
                        WorkspaceChat.State(workspaceWithRepository: item)
                    )
                )
            }
        }
    }
}
