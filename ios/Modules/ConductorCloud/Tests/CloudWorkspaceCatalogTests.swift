//
//  CloudWorkspaceCatalogTests.swift
//  ConductorCloudTests
//
//  Created by Gannon Prudomme on 7/24/26.
//

import ComposableArchitecture
import ConductorMobileData
@testable import ConductorCloud
import Foundation
import Testing

@MainActor
struct CloudWorkspaceCatalogTests {
    @Test("Configured credentials persist a workspace and its lifecycle status")
    func loadCatalog() async throws {
        let project = project()
        let workspace = try workspace()
        let status = CloudWorkspaceStatusResponse(
            workspaceID: workspace.id,
            status: .initializing,
            lifecycleStep: .settingUp,
            updatedAt: Date(timeIntervalSince1970: 3)
        )
        let persistedCatalogs = LockIsolated<[CloudCatalogPersistenceSnapshot]>([])
        let persistedStatuses = LockIsolated<[CloudWorkspaceLifecycleSnapshot]>([])

        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let state = CloudWorkspaceCatalog.State()
            state.$isCloudCredentialConfigured.withLock { $0 = true }
            let store = TestStore(initialState: state) {
                CloudWorkspaceCatalog()
            } withDependencies: {
                $0.cloudCredentialClient.loadAPIKey = { "synthetic-api-key" }
                $0.cloudAPIClient.getIdentity = { _ in identity() }
                $0.cloudAPIClient.getProjects = { _, _ in
                    CloudPage(data: [project], offset: 0, hasMore: false)
                }
                $0.cloudAPIClient.getWorkspaces = { projectID, _, _ in
                    #expect(projectID == project.id)
                    return CloudPage(data: [workspace], offset: 0, hasMore: false)
                }
                $0.cloudAPIClient.getWorkspaceStatus = { workspaceID in
                    #expect(workspaceID == workspace.id)
                    return status
                }
                $0.cloudWorkspacePersistenceClient.replaceCatalog = { snapshot in
                    persistedCatalogs.withValue { $0.append(snapshot) }
                }
                $0.cloudWorkspacePersistenceClient.updateLifecycle = { snapshot in
                    persistedStatuses.withValue { $0.append(snapshot) }
                }
            }

            await store.send(.task) {
                $0.isLoading = true
            }
            await store.receive(\.response) {
                $0.$cloudAccountID.withLock { $0 = identity().cacheID }
                $0.hasLoaded = true
                $0.isLoading = false
            }
            await store.receive(\.statusResponse)

            #expect(persistedCatalogs.value.count == 1)
            #expect(persistedCatalogs.value.first?.workspaces.map(\.id) == [workspace.id])
            #expect(
                persistedStatuses.value.map(\.status)
                    == [CloudWorkspaceStatus.initializing.rawValue]
            )
        }
    }

    @Test("Catalog loading follows project and workspace pagination")
    func pagination() async throws {
        let projectCalls = LockIsolated<[Int]>([])
        let workspaceCalls = LockIsolated<[Int]>([])
        let project = project()
        let workspace = try workspace()

        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let state = CloudWorkspaceCatalog.State()
            state.$isCloudCredentialConfigured.withLock { $0 = true }
            let store = TestStore(initialState: state) {
                CloudWorkspaceCatalog()
            } withDependencies: {
                $0.cloudCredentialClient.loadAPIKey = { "synthetic-api-key" }
                $0.cloudAPIClient.getIdentity = { _ in identity() }
                $0.cloudAPIClient.getProjects = { _, offset in
                    projectCalls.withValue { $0.append(offset) }
                    return offset == 0
                        ? CloudPage(data: [project], offset: 0, hasMore: true)
                        : CloudPage(data: [], offset: 1, hasMore: false)
                }
                $0.cloudAPIClient.getWorkspaces = { _, _, offset in
                    workspaceCalls.withValue { $0.append(offset) }
                    return offset == 0
                        ? CloudPage(data: [workspace], offset: 0, hasMore: true)
                        : CloudPage(data: [], offset: 1, hasMore: false)
                }
                $0.cloudAPIClient.getWorkspaceStatus = { _ in
                    throw CatalogTestError.statusUnavailable
                }
                $0.cloudWorkspacePersistenceClient.replaceCatalog = { _ in }
            }

            await store.send(.task) {
                $0.isLoading = true
            }
            await store.receive(\.response) {
                $0.$cloudAccountID.withLock { $0 = identity().cacheID }
                $0.hasLoaded = true
                $0.isLoading = false
            }
            await store.receive(\.statusResponse)

            #expect(projectCalls.value == [0, 1])
            #expect(workspaceCalls.value == [0, 1])
        }
    }

    @Test("Refresh keeps cached database rows mounted while loading")
    func refresh() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            var state = CloudWorkspaceCatalog.State()
            state.$isCloudCredentialConfigured.withLock { $0 = true }
            state.hasLoaded = true
            let (requests, _) = AsyncStream<Void>.makeStream()
            let store = TestStore(initialState: state) {
                CloudWorkspaceCatalog()
            } withDependencies: {
                $0.cloudCredentialClient.loadAPIKey = {
                    for await _ in requests {
                        break
                    }
                    return nil
                }
            }

            let task = await store.send(.refresh) {
                $0.isLoading = true
            }
            #expect(store.state.hasLoaded)
            await task.cancel()
        }
    }

    @Test("Authentication errors direct the user back to Settings")
    func authenticationError() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            var state = CloudWorkspaceCatalog.State()
            state.$isCloudCredentialConfigured.withLock { $0 = true }
            state.isLoading = true
            let store = TestStore(initialState: state) {
                CloudWorkspaceCatalog()
            }

            await store.send(
                .response(
                    .failure(
                        CloudAPIClientError.requestFailed(statusCode: 401, error: nil)
                    )
                )
            ) {
                $0.failure = .authentication("Conductor Cloud returned HTTP 401.")
                $0.hasLoaded = true
                $0.isLoading = false
            }
        }
    }

    @Test("Network errors preserve cached rows and produce an offline state")
    func offlineError() async {
        let error = URLError(.notConnectedToInternet)

        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            var state = CloudWorkspaceCatalog.State()
            state.$isCloudCredentialConfigured.withLock { $0 = true }
            state.isLoading = true
            let store = TestStore(initialState: state) {
                CloudWorkspaceCatalog()
            }

            await store.send(.response(.failure(error))) {
                $0.failure = .offline(error.localizedDescription)
                $0.hasLoaded = true
                $0.isLoading = false
            }
        }
    }

    @Test("An empty successful catalog is a loaded state, not an error")
    func emptyCatalog() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            var state = CloudWorkspaceCatalog.State()
            state.$isCloudCredentialConfigured.withLock { $0 = true }
            state.isLoading = true
            let store = TestStore(initialState: state) {
                CloudWorkspaceCatalog()
            }

            await store.send(
                .response(
                    .success(
                        .init(
                            accountID: identity().cacheID,
                            projects: [],
                            workspaces: []
                        )
                    )
                )
            ) {
                $0.$cloudAccountID.withLock { $0 = identity().cacheID }
                $0.hasLoaded = true
                $0.isLoading = false
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
                $0.cloudAPIClient.getProjects = { _, _ in
                    Issue.record("Cloud projects should not load without a credential.")
                    return CloudPage(data: [], offset: 0, hasMore: false)
                }
            }

            await store.send(.task)
        }
    }
}

private func identity() -> CloudIdentity {
    CloudIdentity(userID: "user-1", authMethod: .apiKey)
}

private func project() -> CloudProject {
    CloudProject(
        id: "project-1",
        name: "Mobile",
        gitRemote: "https://example.test/mobile.git"
    )
}

private func workspace() throws -> CloudWorkspace {
    CloudWorkspace(
        id: "workspace-1",
        name: "Cloud workspace",
        createdAt: Date(timeIntervalSince1970: 1),
        deepLink: try #require(URL(string: "conductor://workspace/workspace-1")),
        lastActivityAt: Date(timeIntervalSince1970: 2)
    )
}

private enum CatalogTestError: Error {
    case statusUnavailable
}
