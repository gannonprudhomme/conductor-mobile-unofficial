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
    @Test("Cloud snapshots persist projects without workspaces")
    func persistsEmptyProjects() throws {
        let database = try appDatabase()
        let project = CloudProject(
            id: "empty-project",
            name: "Empty",
            gitRemote: "https://github.com/example/empty.git"
        )

        try database.write { database in
            try CloudWorkspacePersistence.persist(
                CloudWorkspaceSnapshot(
                    accountID: "account-1",
                    projects: [project],
                    statuses: [:],
                    workspaces: []
                ),
                in: database
            )
        }

        try database.read { database in
            let mapping = try CloudProjectRepositoryMapping.find(
                CloudProjectRepositoryMapping.id(
                    accountID: "account-1",
                    cloudProjectID: project.id
                )
            )
            .fetchOne(database)
            let repository = try Repository.find(project.id).fetchOne(database)
            #expect(mapping?.canonicalRepositoryID == repository?.id)
            #expect(mapping?.projectName == "Empty")
            #expect(repository?.remoteURL == project.gitRemote)
        }
    }

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

    @Test("Pending workspace rename survives polling until confirmed")
    func pendingWorkspaceRenameReconciliation() throws {
        let database = try appDatabase()
        let workspaceID = "cloud-workspace"

        try database.write { database in
            try CloudWorkspacePersistence.persist(
                cloudSnapshot(workspaceIDs: [workspaceID]),
                in: database
            )
            let rollback = try JSONEncoder.cloudMutation.encode(
                CloudRenameWorkspaceRollback(
                    workspaceName: "Cloud workspace",
                    owningFeature: .workspaces
                )
            )
            let attempt = try CloudPendingMutation(
                accountID: "account-1",
                credentialGeneration: UUID(72),
                operation: .renameWorkspace,
                resourceKind: .workspace,
                request: CloudRenameWorkspaceRequest(
                    name: "Renamed workspace"
                ),
                rollbackPayload: rollback,
                canonicalWorkspaceID: workspaceID,
                remoteWorkspaceID: workspaceID
            )
            var workspace = try #require(
                try Workspace.find(workspaceID).fetchOne(database)
            )
            workspace.workspaceName = "Renamed workspace"
            try Workspace.upsert { workspace }.execute(database)
            try CloudPendingMutation.insert { attempt }.execute(database)

            try CloudWorkspacePersistence.persist(
                cloudSnapshot(workspaceIDs: [workspaceID]),
                in: database
            )
            let pendingWorkspace = try Workspace
                .find(workspaceID)
                .fetchOne(database)
            #expect(pendingWorkspace?.workspaceName == "Renamed workspace")
            #expect(
                try CloudPendingMutation.find(attempt.attemptID)
                    .fetchOne(database) != nil
            )

            try CloudWorkspacePersistence.persist(
                cloudSnapshot(
                    workspaceIDs: [workspaceID],
                    workspaceName: "Renamed workspace"
                ),
                in: database
            )
            let confirmedWorkspace = try Workspace
                .find(workspaceID)
                .fetchOne(database)
            #expect(confirmedWorkspace?.workspaceName == "Renamed workspace")
            #expect(
                try CloudPendingMutation.find(attempt.attemptID)
                    .fetchOne(database) == nil
            )
        }
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

    @Test("Desktop and Cloud snapshot order preserves the same Cloud authority")
    func snapshotOrderPreservesCloudAuthority() throws {
        let desktopWorkspace = Workspace.preview(
            id: "cloud-workspace",
            branch: "desktop-branch",
            createdAt: Date(timeIntervalSince1970: 900),
            creatorUserID: "desktop-creator",
            hostingServerURL: "https://desktop.invalid",
            pinnedAt: "2026-07-28T00:00:00Z",
            repositoryID: "desktop-repository",
            state: .archived,
            unread: 1,
            updatedAt: Date(timeIntervalSince1970: 901),
            workspaceName: "Desktop name"
        )

        let desktopThenCloud = try persistedWorkspace {
            try CloudWorkspacePersistence.persistDesktopWorkspaces(
                [desktopWorkspace],
                in: $0
            )
            try CloudWorkspacePersistence.persist(
                cloudSnapshot(workspaceIDs: [desktopWorkspace.id]),
                in: $0
            )
        }
        let cloudThenDesktop = try persistedWorkspace {
            try CloudWorkspacePersistence.persist(
                cloudSnapshot(workspaceIDs: [desktopWorkspace.id]),
                in: $0
            )
            try CloudWorkspacePersistence.persistDesktopWorkspaces(
                [desktopWorkspace],
                in: $0
            )
        }

        #expect(desktopThenCloud == cloudThenDesktop)
        #expect(desktopThenCloud.branch == "desktop-branch")
        #expect(desktopThenCloud.pinnedAt == "2026-07-28T00:00:00Z")
        #expect(desktopThenCloud.unread == 1)
        #expect(desktopThenCloud.workspaceName == "Cloud workspace")
        #expect(desktopThenCloud.creatorUserID == "creator-1")
        #expect(desktopThenCloud.createdAt == Date(timeIntervalSince1970: 1))
        #expect(desktopThenCloud.updatedAt == Date(timeIntervalSince1970: 2))
        #expect(desktopThenCloud.state == .ready)
        #expect(
            desktopThenCloud.hostingServerURL
                == Workspace.conductorCloudHostingServerURL
        )
        #expect(desktopThenCloud.repositoryID == "project-1")
    }

    @Test("Desktop relay reuses the canonical Cloud workspace identity")
    func desktopRelayReusesCloudIdentity() throws {
        let database = try appDatabase()
        let accountID = "account-1"
        let remoteWorkspaceID = "E8E0E15A-9066-43FC-AB85-9A98C375F789"
        let canonicalWorkspaceID = CloudCanonicalID.workspace(
            accountID: accountID,
            remoteWorkspaceID: remoteWorkspaceID
        )
        let repository = Repository.preview(id: "project-1")
        let cloudWorkspace = Workspace.preview(
            id: canonicalWorkspaceID,
            repositoryID: repository.id
        )
        let desktopWorkspace = Workspace.preview(
            id: remoteWorkspaceID.lowercased(),
            branch: "conductor/desktop-observed",
            repositoryID: repository.id
        )
        let pullRequest = PullRequestSnapshot(
            url: "https://example.test/pull/1",
            isDraft: true,
            isMerged: false
        )

        try database.write { db in
            try Repository.insert { repository }.execute(db)
            try Workspace.insert { cloudWorkspace }.execute(db)
            try CloudWorkspaceMetadata
                .insert {
                    CloudWorkspaceMetadata(
                        workspaceID: canonicalWorkspaceID,
                        accountID: accountID,
                        remoteWorkspaceID: remoteWorkspaceID.lowercased(),
                        lastSeenGeneration: "provisional"
                    )
                }
                .execute(db)

            try CloudWorkspacePersistence.persistDesktopSnapshot(
                WorkspaceListSnapshot(
                    repositories: [repository],
                    workspaces: [
                        WorkspaceSnapshot(
                            workspace: desktopWorkspace,
                            isWorking: true
                        ),
                    ],
                    pullRequests: [
                        desktopWorkspace.id: pullRequest,
                    ]
                ),
                in: db
            )
        }

        try database.read { db in
            let workspaces = try Workspace.all.fetchAll(db)
            let mobileStates = try MobileWorkspaceState.all.fetchAll(db)
            let metadata = try CloudWorkspaceMetadata.all.fetchAll(db)

            #expect(workspaces.map(\.id) == [canonicalWorkspaceID])
            #expect(
                workspaces.first?.branch == "conductor/desktop-observed"
            )
            #expect(mobileStates.map(\.workspaceID) == [canonicalWorkspaceID])
            #expect(mobileStates.first?.pullRequestURL == pullRequest.url)
            #expect(metadata.map(\.workspaceID) == [canonicalWorkspaceID])
        }
    }

    @Test("Cloud refresh removes a late raw desktop workspace duplicate")
    func cloudRefreshConsolidatesDesktopWorkspace() throws {
        let database = try appDatabase()
        let accountID = "account-1"
        let remoteWorkspaceID = "remote-workspace"
        let canonicalWorkspaceID = CloudCanonicalID.workspace(
            accountID: accountID,
            remoteWorkspaceID: remoteWorkspaceID
        )
        let repository = Repository.preview(id: "project-1")
        let cloudWorkspace = Workspace.preview(
            id: canonicalWorkspaceID,
            repositoryID: repository.id
        )
        let desktopWorkspace = Workspace.preview(
            id: remoteWorkspaceID,
            branch: "conductor/desktop-observed",
            repositoryID: repository.id
        )

        try database.write { db in
            try Repository.insert { repository }.execute(db)
            try Workspace
                .insert { [cloudWorkspace, desktopWorkspace] }
                .execute(db)
            try CloudWorkspaceMetadata
                .insert {
                    CloudWorkspaceMetadata(
                        workspaceID: canonicalWorkspaceID,
                        accountID: accountID,
                        remoteWorkspaceID: remoteWorkspaceID,
                        lastSeenGeneration: "provisional"
                    )
                }
                .execute(db)
            try MobileWorkspaceState
                .insert {
                    MobileWorkspaceState(
                        workspaceID: remoteWorkspaceID,
                        isWorking: true
                    )
                }
                .execute(db)

            try CloudWorkspacePersistence.persist(
                cloudSnapshot(workspaceIDs: [remoteWorkspaceID]),
                in: db
            )
        }

        try database.read { db in
            let workspaces = try Workspace.all.fetchAll(db)
            let mobileStates = try MobileWorkspaceState.all.fetchAll(db)
            let metadata = try CloudWorkspaceMetadata.all.fetchAll(db)

            #expect(workspaces.map(\.id) == [canonicalWorkspaceID])
            #expect(
                workspaces.first?.branch == "conductor/desktop-observed"
            )
            #expect(mobileStates.map(\.workspaceID) == [canonicalWorkspaceID])
            #expect(metadata.map(\.workspaceID) == [canonicalWorkspaceID])
        }
    }

    @Test("Cloud refresh consolidates duplicate repositories into the desktop row")
    func consolidatesDuplicateRepositories() throws {
        let database = try appDatabase()
        let localRepository = Repository.preview(
            id: "local-repository",
            name: "conductor-mobile-unofficial",
            remoteURL:
                "https://github.com/gannonprudhomme/conductor-mobile-unofficial",
            rootPath: "/tmp/conductor-shared"
        )
        let personalCloudRepository = Repository.preview(
            id: "personal-cloud-project",
            name: "Conductor Mobile Unofficial",
            remoteURL:
                "git@github.com:gannonprudhomme/conductor-mobile-unofficial.git"
        )
        let organizationCloudRepository = Repository.preview(
            id: "organization-cloud-project",
            name: "Conductor Mobile Unofficial",
            remoteURL:
                "https://github.com/GannonPrudhomme/conductor-mobile-unofficial.git/"
        )
        let localWorkspace = Workspace.preview(
            id: "local-workspace",
            repositoryID: localRepository.id
        )
        let cloudWorkspace = Workspace.preview(
            id: "legacy-cloud-workspace",
            repositoryID: organizationCloudRepository.id
        )

        try database.write { db in
            try Repository
                .insert {
                    [
                        localRepository,
                        personalCloudRepository,
                        organizationCloudRepository,
                    ]
                }
                .execute(db)
            try Workspace
                .insert { [localWorkspace, cloudWorkspace] }
                .execute(db)
            try MobileWorkspaceState
                .insert {
                    MobileWorkspaceState(
                        workspaceID: localWorkspace.id,
                        isWorking: false
                    )
                }
                .execute(db)
            try CloudProjectRepositoryMapping
                .insert {
                    [
                        CloudProjectRepositoryMapping(
                            accountID: "personal-account",
                            cloudProjectID: "personal-project",
                            canonicalRepositoryID: personalCloudRepository.id,
                            projectName: personalCloudRepository.displayName,
                            gitRemote: personalCloudRepository.remoteURL ?? "",
                            refreshGeneration: "previous"
                        ),
                        CloudProjectRepositoryMapping(
                            accountID: "organization-account",
                            cloudProjectID: "project-1",
                            canonicalRepositoryID:
                                organizationCloudRepository.id,
                            projectName:
                                organizationCloudRepository.displayName,
                            gitRemote:
                                organizationCloudRepository.remoteURL ?? "",
                            refreshGeneration: "previous"
                        ),
                    ]
                }
                .execute(db)
            try CloudWorkspacePersistence.persist(
                cloudSnapshot(
                    accountID: "organization-account",
                    workspaceIDs: [],
                    gitRemote:
                        "https://github.com/gannonprudhomme/conductor-mobile-unofficial.git"
                ),
                in: db
            )
        }

        try database.read { db in
            let repositories = try Repository.all.fetchAll(db)
            let workspaces = try Workspace.all.fetchAll(db)
            let mapping = try CloudProjectRepositoryMapping.find(
                CloudProjectRepositoryMapping.id(
                    accountID: "organization-account",
                    cloudProjectID: "project-1"
                )
            )
            .fetchOne(db)

            #expect(repositories.map(\.id) == [localRepository.id])
            #expect(
                Set(workspaces.compactMap(\.repositoryID))
                    == [localRepository.id]
            )
            #expect(mapping?.canonicalRepositoryID == localRepository.id)
        }
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

    @Test("Deleted and omitted workspaces remove Cloud chats before ownership")
    func staleWorkspaceRemovesCloudChatsFirst() throws {
        for isExplicitlyDeleted in [true, false] {
            let database = try appDatabase()
            let workspaceID = "dual-source"
            let desktopSession = Session.preview(
                id: "desktop-session",
                workspaceID: workspaceID
            )
            let desktopMessage = Message(
                id: "desktop-message",
                sessionID: desktopSession.id,
                role: .user,
                content: "Desktop",
                createdAt: .distantPast
            )

            try database.write { db in
                try CloudWorkspacePersistence.persist(
                    cloudSnapshot(workspaceIDs: [workspaceID]),
                    in: db
                )
                try MobileWorkspaceState.insert {
                    MobileWorkspaceState(
                        workspaceID: workspaceID,
                        isWorking: false
                    )
                }
                .execute(db)
                try Session.insert { desktopSession }.execute(db)
                try Message.insert { desktopMessage }.execute(db)
                try persistCloudChat(workspaceID: workspaceID, in: db)

                let nextSnapshot = isExplicitlyDeleted
                    ? cloudSnapshot(
                        workspaceIDs: [workspaceID],
                        status: .deleted
                    )
                    : cloudSnapshot(workspaceIDs: [])
                try CloudWorkspacePersistence.persist(nextSnapshot, in: db)
            }

            let storedRows = try database.read { db in
                (
                    cloudSessionCount: try CloudSessionMetadata.fetchCount(db),
                    cloudMessageCount: try CloudMessageMetadata.fetchCount(db),
                    cloudMessage: try Message
                        .find(
                            CloudCanonicalID.message(
                                accountID: "account-1",
                                remoteSessionID: "cloud-session",
                                eventID: "cloud-event",
                                partOrder: 0
                            )
                        )
                        .fetchOne(db),
                    desktopSession: try Session
                        .find(desktopSession.id)
                        .fetchOne(db),
                    desktopMessage: try Message
                        .find(desktopMessage.id)
                        .fetchOne(db),
                    workspace: try Workspace.find(workspaceID).fetchOne(db),
                    cloudWorkspace: try CloudWorkspaceMetadata
                        .find(workspaceID)
                        .fetchOne(db)
                )
            }
            #expect(storedRows.cloudSessionCount == 0)
            #expect(storedRows.cloudMessageCount == 0)
            #expect(storedRows.cloudMessage == nil)
            #expect(storedRows.desktopSession == desktopSession)
            #expect(storedRows.desktopMessage == desktopMessage)
            #expect(storedRows.workspace != nil)
            #expect(storedRows.workspace?.hostingServerURL == nil)
            #expect(storedRows.workspace?.isCloudHosted == false)
            #expect(storedRows.cloudWorkspace == nil)
        }
    }
}

private func persistedWorkspace(
    _ operation: (Database) throws -> Void
) throws -> Workspace {
    let database = try appDatabase()
    return try database.write { db in
        try operation(db)
        return try #require(
            try Workspace.find("cloud-workspace").fetchOne(db)
        )
    }
}

private func persistCloudChat(
    workspaceID: Workspace.ID,
    in database: Database
) throws {
    let date = Date(timeIntervalSince1970: 100)
    _ = try CloudChatPersistence.persist(
        CloudWorkspaceSessionSnapshot(
            accountID: "account-1",
            workspace: CloudWorkspace(
                id: workspaceID,
                name: "Cloud workspace",
                createdAt: date
            ),
            sessions: [
                CloudSession(
                    id: "cloud-session",
                    deepLink: URL(string: "https://app.conductor.build")!,
                    model: "gpt-5.6-sol"
                ),
            ],
            statuses: [:]
        ),
        in: database
    )
    _ = try CloudChatPersistence.persist(
        CloudTranscriptUpdate(
            accountID: "account-1",
            sessionID: "cloud-session",
            messages: [
                CloudTranscriptMessage(
                    id: "cloud-event",
                    sessionID: "cloud-session",
                    sessionIndex: 1,
                    type: .init(rawValue: "userMessage"),
                    content: .object([
                        "type": .string("userMessage"),
                        "message": .string("Cloud"),
                        "turnId": .string("turn"),
                    ]),
                    receivedAt: date
                ),
            ],
            kind: .complete,
            rawCursor: "cloud-event"
        ),
        in: database
    )
}

private func cloudSnapshot(
    accountID: String = "account-1",
    workspaceIDs: [CloudWorkspace.ID],
    status: CloudWorkspaceStatusResponse.Status = .ready,
    gitRemote: String = "https://github.com/example/mobile.git",
    workspaceName: String = "Cloud workspace"
) -> CloudWorkspaceSnapshot {
    let project = CloudProject(
        id: "project-1",
        name: "Mobile",
        gitRemote: gitRemote
    )
    let workspaces = workspaceIDs.map { workspaceID in
        CloudWorkspace(
            id: workspaceID,
            name: workspaceName,
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
