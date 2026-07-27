//
//  CloudWorkspaceCatalog.swift
//  ConductorCloud
//
//  Created by Gannon Prudomme on 7/24/26.
//

import ComposableArchitecture
import Foundation
import Sharing

@Reducer
public struct CloudWorkspaceCatalog: Sendable {
    @ObservableState
    public struct State: Equatable {
        @Shared(.cloudCredentialConfigured)
        public var isCloudCredentialConfigured

        public var errorMessage: String?
        public var isLoading = false
        public var projects: [CloudProject] = []
        public var statuses: [String: CloudWorkspaceStatusResponse] = [:]
        public var workspaces: [CloudProjectWorkspace] = []

        public init() { }
    }

    public enum Action {
        case refresh
        case response(Result<Snapshot, any Error>)
        case statusResponse(
            workspaceID: String,
            Result<CloudWorkspaceStatusResponse, any Error>
        )
        case task
        case workspaceTapped(CloudProjectWorkspace)
    }

    @Dependency(\.cloudAPIClient) var cloudAPIClient

    public init() { }

    public struct Snapshot: Equatable, Sendable {
        public let projects: [CloudProject]
        public let workspaces: [CloudProjectWorkspace]

        public init(
            projects: [CloudProject],
            workspaces: [CloudProjectWorkspace]
        ) {
            self.projects = projects
            self.workspaces = workspaces
        }
    }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .refresh, .task:
                guard state.isCloudCredentialConfigured else {
                    state.errorMessage = nil
                    state.isLoading = false
                    state.projects = []
                    state.statuses = [:]
                    state.workspaces = []
                    return .none
                }
                guard !state.isLoading else {
                    return .none
                }
                state.errorMessage = nil
                state.isLoading = true
                return .run { send in
                    await send(
                        .response(
                            await Result {
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
                                return Snapshot(
                                    projects: projects,
                                    workspaces: workspaces
                                )
                            }
                        )
                    )
                }

            case let .response(result):
                state.isLoading = false
                switch result {
                case let .failure(error):
                    state.errorMessage = error.localizedDescription
                    return .none

                case let .success(snapshot):
                    state.projects = snapshot.projects
                    state.workspaces = snapshot.workspaces.sorted {
                        ($0.workspace.lastActivityAt ?? $0.workspace.createdAt)
                            > ($1.workspace.lastActivityAt ?? $1.workspace.createdAt)
                    }
                    let liveIDs = Set(snapshot.workspaces.map(\.id))
                    state.statuses = state.statuses.filter { liveIDs.contains($0.key) }
                    return .merge(
                        snapshot.workspaces.map { item in
                            .run { send in
                                await send(
                                    .statusResponse(
                                        workspaceID: item.id,
                                        await Result {
                                            try await cloudAPIClient.workspaceStatus(
                                                workspaceID: item.id
                                            )
                                        }
                                    )
                                )
                            }
                        }
                    )
                }

            case let .statusResponse(workspaceID, result):
                if case let .success(status) = result {
                    state.statuses[workspaceID] = status
                }
                return .none

            case .workspaceTapped:
                return .none
            }
        }
    }
}
