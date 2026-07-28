//
//  CloudWorkspacePersistenceTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/27/26.
//

import ConductorCloud
import Foundation
import SharedConductorData
import SQLiteData
@testable import ConductorMobileData
import Testing

struct CloudWorkspacePersistenceTests {
    @Test("Cloud snapshots create canonical rows with coarse state")
    func createsCanonicalRows() throws {
        let database = try appDatabase()
        let snapshot = cloudSnapshot(
            workspaceIDs: ["cloud-workspace"],
            status: .updating
        )

        try database.write { db in
            try CloudWorkspacePersistence.persist(snapshot, in: db)
        }

        let item = try database.read { db in
            try WorkspaceWithRepository
                .all(workspaceID: "cloud-workspace")
                .fetchOne(db)
        }
        let unwrappedItem = try #require(item)
        #expect(unwrappedItem.workspace.workspaceName == "Cloud workspace")
        #expect(
            unwrappedItem.workspace.hostingServerURL
                == Workspace.conductorCloudHostingServerURL
        )
        #expect(unwrappedItem.workspace.state?.rawValue == "updating")
        #expect(
            unwrappedItem.repository?.remoteURL
                == "https://github.com/example/mobile.git"
        )
        #expect(unwrappedItem.cloudMetadata?.accountID == "account-1")
        #expect(unwrappedItem.isCloudOnly)
    }

    @Test("Cloud persistence matches repositories and preserves desktop-owned fields")
    func preservesDesktopFields() throws {
        let database = try appDatabase()
        let repository = Repository.preview(
            id: "desktop-repository",
            name: "Desktop name",
            remoteURL: "git@github.com:example/mobile.git"
        )
        let workspace = Workspace.preview(
            id: "cloud-workspace",
            branch: "feature/persistence",
            derivedStatus: Workspace.Status.inReview.rawValue,
            manualStatus: Workspace.Status.done.rawValue,
            pinnedAt: "2026-07-27T00:00:00Z",
            prDescription: "Desktop PR description",
            prTitle: "Desktop PR",
            repositoryID: repository.id,
            unread: 1,
            workspaceName: "Desktop workspace"
        )
        let pullRequest = PullRequestSnapshot(
            url: "https://example.test/mobile/pull/1",
            isDraft: true,
            isMerged: false
        )
        try database.write { db in
            try Repository.insert { repository }.execute(db)
            try Workspace.insert { workspace }.execute(db)
            try MobileWorkspaceState
                .insert {
                    MobileWorkspaceState(
                        workspaceID: workspace.id,
                        isWorking: true,
                        pullRequest: pullRequest
                    )
                }
                .execute(db)
            try CloudWorkspacePersistence.persist(
                cloudSnapshot(workspaceIDs: [workspace.id]),
                in: db
            )
        }

        let item = try database.read { db in
            try WorkspaceWithRepository
                .all(workspaceID: workspace.id)
                .fetchOne(db)
        }
        let unwrappedItem = try #require(item)
        #expect(unwrappedItem.workspace.branch == "feature/persistence")
        #expect(
            unwrappedItem.workspace.manualStatus
                == Workspace.Status.done.rawValue
        )
        #expect(
            unwrappedItem.workspace.derivedStatus
                == Workspace.Status.inReview.rawValue
        )
        #expect(unwrappedItem.workspace.pinnedAt == "2026-07-27T00:00:00Z")
        #expect(unwrappedItem.workspace.unread == 1)
        #expect(unwrappedItem.workspace.prTitle == "Desktop PR")
        #expect(
            unwrappedItem.workspace.prDescription
                == "Desktop PR description"
        )
        #expect(unwrappedItem.repository?.id == repository.id)
        #expect(unwrappedItem.repository?.name == "Desktop name")
        #expect(unwrappedItem.isWorking)
        #expect(unwrappedItem.pullRequestStatus == .draft)
        #expect(!unwrappedItem.isCloudOnly)

        let repositoryCount = try database.read { db in
            try Repository.fetchCount(db)
        }
        #expect(repositoryCount == 1)
    }

    @Test("Account replacement removes only stale API-owned rows")
    func replacesAccountAndReconcilesStaleRows() throws {
        let database = try appDatabase()
        let workspaceIDs = ["cloud-only", "desktop-and-cloud", "session-and-cloud"]

        try database.write { db in
            try CloudWorkspacePersistence.persist(
                cloudSnapshot(workspaceIDs: workspaceIDs),
                in: db
            )
            try MobileWorkspaceState
                .insert {
                    MobileWorkspaceState(
                        workspaceID: "desktop-and-cloud",
                        isWorking: false
                    )
                }
                .execute(db)
            try Session
                .insert {
                    Session.preview(
                        id: "session",
                        workspaceID: "session-and-cloud"
                    )
                }
                .execute(db)

            try CloudWorkspacePersistence.persist(
                CloudWorkspaceSnapshot(
                    accountID: "account-2",
                    projects: [],
                    statuses: [:],
                    workspaces: []
                ),
                in: db
            )
        }

        try database.read { db in
            let cloudOnly = try Workspace.find("cloud-only").fetchOne(db)
            let desktopAndCloud = try Workspace
                .find("desktop-and-cloud")
                .fetchOne(db)
            let sessionAndCloud = try Workspace
                .find("session-and-cloud")
                .fetchOne(db)
            let metadataCount = try CloudWorkspaceMetadata.fetchCount(db)
            let repository = try Repository.find("project-1").fetchOne(db)

            #expect(cloudOnly == nil)
            #expect(desktopAndCloud != nil)
            #expect(sessionAndCloud != nil)
            #expect(metadataCount == 0)
            #expect(repository != nil)
        }
    }

    @Test("Cleanup preserves a canonical desktop repository and workspace")
    func cleanupPreservesDesktopCanonicalRows() throws {
        let database = try appDatabase()
        let repository = Repository.preview(id: "desktop-repository")
        let workspace = Workspace.preview(
            id: "desktop-workspace",
            repositoryID: repository.id
        )

        try database.write { db in
            try Repository.insert { repository }.execute(db)
            try Workspace.insert { workspace }.execute(db)
            try MobileWorkspaceState
                .insert {
                    MobileWorkspaceState(
                        workspaceID: workspace.id,
                        isWorking: false
                    )
                }
                .execute(db)
            try CloudWorkspaceMetadata
                .insert {
                    CloudWorkspaceMetadata(
                        workspaceID: workspace.id,
                        accountID: "stale-account",
                        lastSeenGeneration: "stale-generation"
                    )
                }
                .execute(db)
            try CloudWorkspaceMetadata.clearCachedRows(in: db)
        }

        try database.read { db in
            let persistedRepository = try Repository
                .find(repository.id)
                .fetchOne(db)
            let persistedWorkspace = try Workspace
                .find(workspace.id)
                .fetchOne(db)
            let persistedMetadata = try CloudWorkspaceMetadata
                .find(workspace.id)
                .fetchOne(db)
            #expect(persistedRepository != nil)
            #expect(persistedWorkspace != nil)
            #expect(persistedMetadata == nil)
        }
    }

    @Test("A deleted Cloud workspace removes an API-only cached row")
    func deletedWorkspaceRemovesAPIOnlyRow() throws {
        let database = try appDatabase()

        try database.write { db in
            try CloudWorkspacePersistence.persist(
                cloudSnapshot(workspaceIDs: ["deleted-workspace"]),
                in: db
            )
            try CloudWorkspacePersistence.persist(
                cloudSnapshot(
                    workspaceIDs: ["deleted-workspace"],
                    status: .deleted
                ),
                in: db
            )
        }

        try database.read { db in
            let workspace = try Workspace
                .find("deleted-workspace")
                .fetchOne(db)
            let repository = try Repository.find("project-1").fetchOne(db)
            #expect(workspace == nil)
            #expect(repository != nil)
        }
    }

    @Test("A deleted Cloud workspace preserves its desktop-owned canonical row")
    func deletedWorkspacePreservesDesktopRow() throws {
        let database = try appDatabase()

        try database.write { db in
            try CloudWorkspacePersistence.persist(
                cloudSnapshot(workspaceIDs: ["desktop-workspace"]),
                in: db
            )
            try MobileWorkspaceState
                .insert {
                    MobileWorkspaceState(
                        workspaceID: "desktop-workspace",
                        isWorking: false
                    )
                }
                .execute(db)
            try CloudWorkspacePersistence.persist(
                cloudSnapshot(
                    workspaceIDs: ["desktop-workspace"],
                    status: .deleted
                ),
                in: db
            )
        }

        try database.read { db in
            let workspace = try Workspace
                .find("desktop-workspace")
                .fetchOne(db)
            let metadata = try CloudWorkspaceMetadata
                .find("desktop-workspace")
                .fetchOne(db)
            #expect(workspace != nil)
            #expect(metadata == nil)
        }
    }
}

private func cloudSnapshot(
    accountID: String = "account-1",
    workspaceIDs: [CloudWorkspace.ID],
    status: CloudWorkspaceStatusResponse.Status = .ready
) -> CloudWorkspaceSnapshot {
    let project = CloudProject(
        id: "project-1",
        name: "Mobile",
        gitRemote: "https://github.com/example/mobile.git"
    )
    let workspaces = workspaceIDs.map { workspaceID in
        CloudWorkspace(
            id: workspaceID,
            name: "Cloud workspace",
            createdAt: Date(timeIntervalSince1970: 1),
            creatorID: "creator-1",
            lastActivityAt: Date(timeIntervalSince1970: 2)
        )
    }
    return CloudWorkspaceSnapshot(
        accountID: accountID,
        projects: [project],
        statuses: Dictionary(
            uniqueKeysWithValues: workspaces.map { workspace in
                (
                    workspace.id,
                    CloudWorkspaceStatusResponse(
                        workspaceID: workspace.id,
                        status: status
                    )
                )
            }
        ),
        workspaces: workspaces.map {
            CloudProjectWorkspace(project: project, workspace: $0)
        }
    )
}
