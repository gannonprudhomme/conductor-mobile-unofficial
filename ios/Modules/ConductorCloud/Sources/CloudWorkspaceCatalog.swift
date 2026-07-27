//
//  CloudWorkspaceCatalog.swift
//  ConductorCloud
//
//  Created by Gannon Prudomme on 7/24/26.
//

import ComposableArchitecture
import ConductorMobileData
import Foundation
import Sharing

@Reducer
public struct CloudWorkspaceCatalog: Sendable {
    @ObservableState
    public struct State: Equatable {
        @Shared(.cloudCredentialConfigured)
        public var isCloudCredentialConfigured

        @Shared(.cloudAccountID)
        public var cloudAccountID

        public var failure: Failure?
        public var hasLoaded = false
        public var isLoading = false

        public init() { }
    }

    public enum Action {
        case refresh
        case response(Result<Snapshot, any Error>)
        case statusResponse(workspaceID: String, Result<Void, any Error>)
        case task
    }

    public enum Failure: Equatable, Sendable {
        case authentication(String)
        case offline(String)
        case other(String)

        public var title: String {
            switch self {
            case .authentication:
                "Cloud authentication failed"

            case .offline:
                "Cloud is unavailable offline"

            case .other:
                "Cloud workspaces failed to load"
            }
        }

        public var message: String {
            switch self {
            case let .authentication(message),
                 let .offline(message),
                 let .other(message):
                message
            }
        }

        static func from(_ error: any Error) -> Self {
            if let apiError = error as? CloudAPIClientError,
               apiError.isAuthenticationFailure || apiError == .missingCredential {
                return .authentication(apiError.localizedDescription)
            }
            if error is URLError {
                return .offline(error.localizedDescription)
            }
            return .other(error.localizedDescription)
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let accountID: String
        public let projects: [CloudProject]
        public let workspaces: [CloudProjectWorkspace]

        public init(
            accountID: String,
            projects: [CloudProject],
            workspaces: [CloudProjectWorkspace]
        ) {
            self.accountID = accountID
            self.projects = projects
            self.workspaces = workspaces
        }

        var persistenceSnapshot: CloudCatalogPersistenceSnapshot {
            CloudCatalogPersistenceSnapshot(
                accountID: accountID,
                projects: projects.map {
                    CloudCatalogProjectSnapshot(
                        id: $0.id,
                        name: $0.name,
                        gitRemote: $0.gitRemote
                    )
                },
                workspaces: workspaces.map {
                    CloudCatalogWorkspaceSnapshot(
                        id: $0.id,
                        projectID: $0.project.id,
                        name: $0.workspace.name,
                        createdAt: $0.workspace.createdAt,
                        updatedAt: $0.workspace.lastActivityAt
                            ?? $0.workspace.createdAt,
                        creatorID: $0.workspace.creatorID,
                        deepLink: $0.workspace.deepLink.absoluteString
                    )
                }
            )
        }
    }

    @Dependency(\.cloudAPIClient) var cloudAPIClient
    @Dependency(\.cloudCredentialClient) var cloudCredentialClient
    @Dependency(\.cloudWorkspacePersistenceClient) var cloudWorkspacePersistenceClient

    public init() { }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .refresh, .task:
                guard state.isCloudCredentialConfigured else {
                    state.failure = nil
                    state.hasLoaded = false
                    state.isLoading = false
                    return .merge(
                        .cancel(id: CancelID.catalog),
                        .cancel(id: CancelID.statuses)
                    )
                }
                guard !state.isLoading else {
                    return .none
                }
                state.failure = nil
                state.isLoading = true
                return .merge(
                    .cancel(id: CancelID.statuses),
                    .run { send in
                        await send(
                            .response(
                                await Result {
                                    guard let apiKey = try await cloudCredentialClient
                                        .loadAPIKey() else {
                                        throw CloudAPIClientError.missingCredential
                                    }
                                    let identity = try await cloudAPIClient.getIdentity(
                                        apiKey: apiKey
                                    )
                                    let projects = try await cloudAPIClient.allProjects()
                                    var workspaces: [CloudProjectWorkspace] = []
                                    for project in projects {
                                        let projectWorkspaces = try await cloudAPIClient
                                            .allWorkspaces(projectID: project.id)
                                        workspaces.append(
                                            contentsOf: projectWorkspaces.map {
                                                CloudProjectWorkspace(
                                                    project: project,
                                                    workspace: $0
                                                )
                                            }
                                        )
                                    }
                                    let snapshot = Snapshot(
                                        accountID: identity.cacheID,
                                        projects: projects,
                                        workspaces: workspaces
                                    )
                                    try await cloudWorkspacePersistenceClient.replaceCatalog(
                                        snapshot: snapshot.persistenceSnapshot
                                    )
                                    return snapshot
                                }
                            )
                        )
                    }
                    .cancellable(id: CancelID.catalog, cancelInFlight: true)
                )

            case let .response(result):
                state.hasLoaded = true
                state.isLoading = false
                switch result {
                case let .failure(error):
                    state.failure = .from(error)
                    return .none

                case let .success(snapshot):
                    state.failure = nil
                    state.$cloudAccountID.withLock { $0 = snapshot.accountID }
                    return .merge(
                        snapshot.workspaces.map { item in
                            .run { [accountID = snapshot.accountID] send in
                                await send(
                                    .statusResponse(
                                        workspaceID: item.id,
                                        await Result {
                                            let status = try await cloudAPIClient
                                                .getWorkspaceStatus(
                                                    workspaceID: item.id
                                                )
                                            try await cloudWorkspacePersistenceClient
                                                .updateLifecycle(
                                                    snapshot: .init(
                                                        accountID: accountID,
                                                        workspaceID: item.id,
                                                        status: status.status.rawValue,
                                                        lifecycleStep: status
                                                            .lifecycleStep?.rawValue,
                                                        errorMessage: status.errorMessage,
                                                        updatedAt: status.updatedAt
                                                    )
                                                )
                                        }
                                    )
                                )
                            }
                        }
                    )
                    .cancellable(id: CancelID.statuses, cancelInFlight: true)
                }

            case .statusResponse:
                return .none
            }
        }
    }

    private enum CancelID: Hashable {
        case catalog
        case statuses
    }
}
