//
//  CloudWorkspaceCatalogTests.swift
//  ConductorCloudTests
//
//  Created by Gannon Prudomme on 7/24/26.
//

import ComposableArchitecture
@testable import ConductorCloud
import Foundation
import Testing

@MainActor
struct CloudWorkspaceCatalogTests {
    @Test("Configured cloud credentials load projects, workspaces, and lifecycle separately")
    func loadCatalog() async throws {
        let project = CloudProject(
            id: "project-1",
            name: "Mobile",
            gitRemote: "https://example.test/mobile.git"
        )
        let workspace = CloudWorkspace(
            id: "workspace-1",
            name: "Cloud workspace",
            createdAt: Date(timeIntervalSince1970: 1),
            deepLink: try #require(URL(string: "conductor://workspace/workspace-1")),
            lastActivityAt: Date(timeIntervalSince1970: 2)
        )
        let status = CloudWorkspaceStatusResponse(
            workspaceID: workspace.id,
            status: .ready,
            updatedAt: Date(timeIntervalSince1970: 3)
        )
        let item = CloudProjectWorkspace(project: project, workspace: workspace)

        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let initialState = CloudWorkspaceCatalog.State()
            initialState.$isCloudCredentialConfigured.withLock { $0 = true }
            let store = TestStore(initialState: initialState) {
                CloudWorkspaceCatalog()
            } withDependencies: {
                $0.cloudAPIClient.projects = { _, _ in
                    CloudPage(data: [project], offset: 0, hasMore: false)
                }
                $0.cloudAPIClient.workspaces = { projectID, _, _ in
                    #expect(projectID == project.id)
                    return CloudPage(data: [workspace], offset: 0, hasMore: false)
                }
                $0.cloudAPIClient.workspaceStatus = { workspaceID in
                    #expect(workspaceID == workspace.id)
                    return status
                }
            }

            await store.send(.task) {
                $0.isLoading = true
            }
            await store.receive(\.response) {
                $0.isLoading = false
                $0.projects = [project]
                $0.workspaces = [item]
            }
            await store.receive(\.statusResponse) {
                $0.statuses[workspace.id] = status
            }
        }
    }

    @Test("Without a cloud credential the local app does not issue cloud requests")
    func disabledCatalog() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let store = TestStore(initialState: CloudWorkspaceCatalog.State()) {
                CloudWorkspaceCatalog()
            } withDependencies: {
                $0.cloudAPIClient.projects = { _, _ in
                    Issue.record("Cloud projects should not load without a credential.")
                    return CloudPage(data: [], offset: 0, hasMore: false)
                }
            }

            await store.send(.task)
        }
    }
}
