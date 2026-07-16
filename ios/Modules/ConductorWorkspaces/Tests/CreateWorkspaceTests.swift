//
//  CreateWorkspaceTests.swift
//  ConductorWorkspacesTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import ComposableArchitecture
import CustomDump
import Foundation
import SharedConductorData
@testable import ConductorWorkspaces
import Testing

@MainActor
struct CreateWorkspaceTests {
    @Test("Repository selection uses the requested repository when available")
    func repositorySelection() {
        let first = Repository.preview(id: "first")
        let selected = Repository.preview(id: "selected")

        expectNoDifference(
            CreateWorkspace.State(
                repositories: [first, selected],
                selectedRepositoryIDFilter: selected.id
            ).selectedRepositoryID,
            selected.id
        )
        expectNoDifference(
            CreateWorkspace.State(
                repositories: [first, selected],
                selectedRepositoryIDFilter: "missing"
            ).selectedRepositoryID,
            first.id
        )
        expectNoDifference(
            CreateWorkspace.State(
                repositories: [first, selected]
            ).selectedRepositoryID,
            first.id
        )
    }

    @Test("Create sends the selected repository and prompt")
    func createWorkspace() async {
        let repository = Repository.preview()
        let state = CreateWorkspace.State(repositories: [repository])
        state.$prompt.withLock { $0 = "Build the create sheet" }
        let store = TestStore(initialState: state) {
            CreateWorkspace()
        } withDependencies: {
            $0.desktopClient.createWorkspace = { repositoryID, prompt in
                #expect(repositoryID == repository.id)
                #expect(prompt == "Build the create sheet")
            }
        }

        await store.send(.createButtonTapped) {
            $0.isCreateAPIInFlight = true
        }
        await store.receive(\.createWorkspaceSucceeded) {
            $0.isCreateAPIInFlight = false
        }
        await store.receive(\.delegate)
    }

    @Test("Create preserves input and shows an alert when creation fails")
    func createWorkspaceFailure() async {
        let repository = Repository.preview()
        let state = CreateWorkspace.State(repositories: [repository])
        state.$prompt.withLock { $0 = "Keep this prompt" }
        let store = TestStore(initialState: state) {
            CreateWorkspace()
        } withDependencies: {
            $0.desktopClient.createWorkspace = { _, _ in
                throw TestError()
            }
        }

        await store.send(.createButtonTapped) {
            $0.isCreateAPIInFlight = true
        }
        await store.receive(\.createWorkspaceFailed) {
            $0.alert = .failedToCreateWorkspace(message: TestError().localizedDescription)
            $0.isCreateAPIInFlight = false
        }
    }
}

private struct TestError: LocalizedError {
    var errorDescription: String? {
        "Something went wrong."
    }
}
