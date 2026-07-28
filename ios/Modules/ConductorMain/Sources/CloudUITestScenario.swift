//
//  CloudUITestScenario.swift
//  ConductorMain
//
//  Created by Gannon Prudomme on 7/27/26.
//

#if DEBUG
import ConductorCloud
import ConductorMobileData
import Dependencies
import Foundation
import SharedConductorData
import Sharing
import SQLiteData

public enum CloudUITestScenario: String, Sendable {
    case cloudAuthenticationFailure = "cloud-authentication-failure"
    case cloudConnectAndBrowse = "cloud-connect-and-browse"
    case cloudOnlyLoading = "cloud-only-loading"
    case localOnly = "local-only"

    public func install(in dependencies: inout DependencyValues) throws {
        let credential = LockIsolated<String?>(
            self == .localOnly ? nil : "fixture-api-key"
        )
        dependencies.cloudCredentialClient.loadAPIKey = {
            credential.value
        }
        dependencies.cloudCredentialClient.saveAPIKey = { apiKey in
            credential.withValue { $0 = apiKey }
        }
        dependencies.cloudCredentialClient.deleteAPIKey = {
            credential.withValue { $0 = nil }
        }
        let fixtureIdentity = self.fixtureIdentity
        dependencies.cloudAPIClient.getIdentity = {
            fixtureIdentity
        }
        dependencies.cloudAPIClient.validateIdentity = { apiKey in
            guard apiKey == "fixture-api-key" else {
                throw CloudAPIClientError.requestFailed(
                    statusCode: 401,
                    error: nil
                )
            }
            return fixtureIdentity
        }
        dependencies.cloudAPIClient.observeWorkspaces = {
            self.cloudObservation
        }
        dependencies.desktopClient.checkConnection = { _ in }
        dependencies.desktopClient.observeWorkspaces = {
            self.desktopObservation
        }
        dependencies.desktopClient.ping = { }

        @Shared(.cloudConfiguration) var cloudConfiguration
        @Shared(.desktopConnectionStatus) var desktopConnectionStatus
        @Shared(.desktopDisplayConfiguration) var desktopDisplayConfiguration
        @Shared(.desktopServerAddress) var desktopServerAddress
        $cloudConfiguration.withLock {
            $0 = self == .localOnly
                ? nil
                : CloudConfiguration(accountID: fixtureIdentity.cacheID)
        }
        $desktopConnectionStatus.withLock {
            $0 = hasLocalConnection ? .connected : .disconnected
        }
        $desktopDisplayConfiguration.withLock {
            $0 = hasLocalConnection
                ? DesktopClient.DisplayConfiguration(
                    name: "MacBook Pro",
                    icon: .laptop
                )
                : nil
        }
        $desktopServerAddress.withLock {
            $0 = hasLocalConnection ? "fixture-mac" : nil
        }

        let rows = fixtureRows
        try dependencies.defaultDatabase.write { database in
            try Repository.upsert { rows.repositories }.execute(database)
            try Workspace.upsert { rows.workspaces }.execute(database)
            if !rows.cloudMetadata.isEmpty {
                try CloudWorkspaceMetadata
                    .upsert { rows.cloudMetadata }
                    .execute(database)
            }
            if !rows.mobileStates.isEmpty {
                try MobileWorkspaceState
                    .upsert { rows.mobileStates }
                    .execute(database)
            }
        }
    }

    private var cloudObservation: AsyncThrowingStream<
        CloudWorkspaceSnapshot,
        any Error
    > {
        AsyncThrowingStream { continuation in
            switch self {
            case .cloudAuthenticationFailure:
                continuation.finish(
                    throwing: CloudAPIClientError.requestFailed(
                        statusCode: 401,
                        error: nil
                    )
                )

            case .cloudConnectAndBrowse:
                continuation.yield(fixtureCloudSnapshot)

            case .cloudOnlyLoading, .localOnly:
                break
            }
        }
    }

    private var desktopObservation: AsyncThrowingStream<
        WorkspaceListSnapshot,
        any Error
    > {
        AsyncThrowingStream { continuation in
            guard hasLocalConnection else {
                return
            }
            let rows = fixtureRows
            let mobileStates = Dictionary(
                uniqueKeysWithValues: rows.mobileStates.map {
                    ($0.workspaceID, $0)
                }
            )
            continuation.yield(
                WorkspaceListSnapshot(
                    repositories: rows.repositories,
                    workspaces: rows.workspaces.compactMap { workspace in
                        guard let mobileState = mobileStates[workspace.id] else {
                            return nil
                        }
                        return WorkspaceSnapshot(
                            workspace: workspace,
                            isWorking: mobileState.isWorking
                        )
                    },
                    pullRequests: Dictionary(
                        uniqueKeysWithValues: rows.mobileStates.compactMap {
                            mobileState in
                            guard let url = mobileState.pullRequestURL else {
                                return nil
                            }
                            return (
                                mobileState.workspaceID,
                                PullRequestSnapshot(
                                    url: url,
                                    isDraft: mobileState.isPullRequestDraft,
                                    isMerged: mobileState.isPullRequestMerged,
                                    mergeStateStatus: mobileState
                                        .pullRequestMergeStateStatus,
                                    checksStatus: mobileState
                                        .pullRequestChecksStatus
                                )
                            )
                        }
                    )
                )
            )
        }
    }

    private var fixtureRows: FixtureRows {
        let date = Date(timeIntervalSince1970: 1_783_555_200)
        let repository = Repository(
            id: "fixture-repository",
            createdAt: date,
            name: "Cloud fixtures",
            remoteURL: "https://github.com/example/fixtures.git",
            rootPath: "/tmp/cloud-fixtures",
            updatedAt: date
        )
        let cloudOnlyWorkspace = Workspace(
            id: "cloud-only",
            createdAt: date,
            derivedStatus: Workspace.Status.inProgress.rawValue,
            hostingServerURL: Workspace.conductorCloudHostingServerURL,
            repositoryID: repository.id,
            state: .initializing,
            updatedAt: date.addingTimeInterval(3),
            workspaceName: "Cloud only fixture"
        )
        let localDraftWorkspace = Workspace(
            id: "local-draft",
            createdAt: date,
            derivedStatus: Workspace.Status.inProgress.rawValue,
            hostingServerURL: hasCloudConnection
                ? Workspace.conductorCloudHostingServerURL
                : nil,
            repositoryID: repository.id,
            state: .ready,
            updatedAt: date.addingTimeInterval(2),
            workspaceName: "Local draft fixture"
        )
        let localWorkingWorkspace = Workspace(
            id: "local-working",
            createdAt: date,
            derivedStatus: Workspace.Status.inProgress.rawValue,
            hostingServerURL: hasCloudConnection
                ? Workspace.conductorCloudHostingServerURL
                : nil,
            repositoryID: repository.id,
            state: .ready,
            updatedAt: date.addingTimeInterval(1),
            workspaceName: "Local working fixture"
        )
        let workspaces = hasLocalConnection
            ? hasCloudConnection
                ? [
                    cloudOnlyWorkspace,
                    localDraftWorkspace,
                    localWorkingWorkspace,
                ]
                : [localDraftWorkspace, localWorkingWorkspace]
            : [cloudOnlyWorkspace]
        let cloudMetadata = hasCloudConnection
            ? workspaces.map {
                CloudWorkspaceMetadata(
                    workspaceID: $0.id,
                    accountID: fixtureIdentity.cacheID,
                    lastSeenGeneration: "fixture-generation"
                )
            }
            : []
        let mobileStates = hasLocalConnection
            ? [
                MobileWorkspaceState(
                    workspaceID: localDraftWorkspace.id,
                    isWorking: false,
                    pullRequest: PullRequestSnapshot(
                        url: "https://github.com/example/fixtures/pull/1",
                        isDraft: true,
                        isMerged: false
                    )
                ),
                MobileWorkspaceState(
                    workspaceID: localWorkingWorkspace.id,
                    isWorking: true
                ),
            ]
            : []
        return FixtureRows(
            cloudMetadata: cloudMetadata,
            mobileStates: mobileStates,
            repositories: [repository],
            workspaces: workspaces
        )
    }

    private var hasCloudConnection: Bool {
        self != .localOnly
    }

    private var hasLocalConnection: Bool {
        self == .cloudConnectAndBrowse || self == .localOnly
    }

    private var fixtureCloudSnapshot: CloudWorkspaceSnapshot {
        let project = CloudProject(
            id: "fixture-project",
            name: "Cloud fixtures",
            gitRemote: "https://github.com/example/fixtures.git"
        )
        let workspaces = fixtureRows.workspaces.map {
            CloudWorkspace(
                id: $0.id,
                name: $0.workspaceName ?? $0.id,
                createdAt: $0.createdAt,
                lastActivityAt: $0.updatedAt
            )
        }
        return CloudWorkspaceSnapshot(
            accountID: fixtureIdentity.cacheID,
            projects: [project],
            statuses: Dictionary(
                uniqueKeysWithValues: workspaces.map {
                    (
                        $0.id,
                        CloudWorkspaceStatusResponse(
                            workspaceID: $0.id,
                            status: $0.id == "cloud-only"
                                ? .initializing
                                : .ready
                        )
                    )
                }
            ),
            workspaces: workspaces.map {
                CloudProjectWorkspace(project: project, workspace: $0)
            }
        )
    }

    private var fixtureIdentity: CloudIdentity {
        CloudIdentity(
            userID: "fixture-account",
            authMethod: .apiKey
        )
    }

    private struct FixtureRows {
        var cloudMetadata: [CloudWorkspaceMetadata]
        var mobileStates: [MobileWorkspaceState]
        var repositories: [Repository]
        var workspaces: [Workspace]
    }
}
#endif
