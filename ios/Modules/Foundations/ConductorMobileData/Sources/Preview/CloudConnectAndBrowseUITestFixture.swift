//
//  CloudConnectAndBrowseUITestFixture.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/27/26.
//

#if DEBUG
import Dependencies
import Foundation
import SharedConductorData
import Sharing
import SQLiteData

public func prepareCloudConnectAndBrowseUITestFixture() {
    @Shared(.desktopServerAddress) var desktopServerAddress
    $desktopServerAddress.withLock { $0 = "127.0.0.1:1" }

    Task {
        @Dependency(\.defaultDatabase) var database
        let date = Date().addingTimeInterval(86_400)
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
            hostingServerURL: "https://api.conductor.build",
            repositoryID: repository.id,
            state: .initializing,
            updatedAt: date.addingTimeInterval(3),
            workspaceName: "Cloud only fixture"
        )
        let localDraftWorkspace = Workspace(
            id: "local-draft",
            createdAt: date,
            derivedStatus: Workspace.Status.inProgress.rawValue,
            hostingServerURL: "https://api.conductor.build",
            repositoryID: repository.id,
            state: .ready,
            updatedAt: date.addingTimeInterval(2),
            workspaceName: "Local draft fixture"
        )
        let localWorkingWorkspace = Workspace(
            id: "local-working",
            createdAt: date,
            derivedStatus: Workspace.Status.inProgress.rawValue,
            hostingServerURL: "https://api.conductor.build",
            repositoryID: repository.id,
            state: .ready,
            updatedAt: date.addingTimeInterval(1),
            workspaceName: "Local working fixture"
        )
        let metadata = [
            CloudWorkspaceMetadata(
                workspaceID: cloudOnlyWorkspace.id,
                accountID: "fixture-account",
                cloudProjectID: "fixture-project",
                deepLink: "conductor://workspace/cloud-only",
                lifecycleStep: "preparing",
                lastSeenGeneration: "fixture-generation"
            ),
            CloudWorkspaceMetadata(
                workspaceID: localDraftWorkspace.id,
                accountID: "fixture-account",
                cloudProjectID: "fixture-project",
                deepLink: "conductor://workspace/local-draft",
                lastSeenGeneration: "fixture-generation"
            ),
            CloudWorkspaceMetadata(
                workspaceID: localWorkingWorkspace.id,
                accountID: "fixture-account",
                cloudProjectID: "fixture-project",
                deepLink: "conductor://workspace/local-working",
                lastSeenGeneration: "fixture-generation"
            ),
        ]
        let mobileStates = [
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

        try await database.write { database in
            try Repository.upsert { repository }.execute(database)
            try Workspace
                .upsert {
                    [
                        cloudOnlyWorkspace,
                        localDraftWorkspace,
                        localWorkingWorkspace,
                    ]
                }
                .execute(database)
            try CloudWorkspaceMetadata.upsert { metadata }.execute(database)
            try MobileWorkspaceState.upsert { mobileStates }.execute(database)
        }
    }
}
#endif
