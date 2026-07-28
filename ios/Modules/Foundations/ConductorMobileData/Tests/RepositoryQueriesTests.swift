//
//  RepositoryQueriesTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
@testable import ConductorMobileData
import CustomDump
import Testing

struct RepositoryQueriesTests {
    @Test("All repositories are stably sorted by name")
    func sortedByName() throws {
        let database = try appDatabase()

        try database.write { db in
            try Repository.insert { Repository.preview(id: "repo-1", name: "TrialSongs") }.execute(db)
            try Repository.insert { Repository.preview(id: "repo-2", name: "conductor-mobile") }.execute(db)
            try Repository.insert { Repository.preview(id: "repo-3", name: "Empty") }.execute(db)
            try Repository.insert { Repository.preview(id: "repo-4", name: "MovieRating") }.execute(db)
            try Repository.insert { Repository.preview(id: "repo-5", name: "conductor-mobile") }.execute(db)
        }

        let repositories = try database.read { db in
            try Repository.all
                .order { ($0.name.lower(), $0.id) }
                .fetchAll(db)
        }

        expectNoDifference(
            repositories.map(\.id),
            ["repo-2", "repo-5", "repo-3", "repo-4", "repo-1"]
        )
    }

    @Test("Local creation excludes Cloud-only repositories and retains shared ones")
    func availableForLocalWorkspaceCreation() throws {
        let database = try appDatabase()
        let localRepository = Repository.preview(id: "local", name: "Local")
        let cloudRepository = Repository.preview(id: "cloud", name: "Cloud")
        let sharedRepository = Repository.preview(id: "shared", name: "Shared")
        let unusedRepository = Repository.preview(id: "unused", name: "Unused")
        let localWorkspace = Workspace.preview(
            id: "local-workspace",
            repositoryID: localRepository.id
        )
        let cloudWorkspace = Workspace.preview(
            id: "cloud-workspace",
            hostingServerURL: Workspace.conductorCloudHostingServerURL,
            repositoryID: cloudRepository.id
        )
        let sharedWorkspace = Workspace.preview(
            id: "shared-workspace",
            hostingServerURL: Workspace.conductorCloudHostingServerURL,
            repositoryID: sharedRepository.id
        )

        try database.write { db in
            try Repository
                .insert {
                    [
                        localRepository,
                        cloudRepository,
                        sharedRepository,
                        unusedRepository,
                    ]
                }
                .execute(db)
            try Workspace
                .insert {
                    [localWorkspace, cloudWorkspace, sharedWorkspace]
                }
                .execute(db)
            try CloudWorkspaceMetadata
                .insert {
                    [
                        cloudMetadata(
                            workspaceID: cloudWorkspace.id,
                            projectID: cloudRepository.id
                        ),
                        cloudMetadata(
                            workspaceID: sharedWorkspace.id,
                            projectID: sharedRepository.id
                        ),
                    ]
                }
                .execute(db)
            try MobileWorkspaceState
                .insert {
                    MobileWorkspaceState(
                        workspaceID: sharedWorkspace.id,
                        isWorking: false
                    )
                }
                .execute(db)
        }

        let repositories = try database.read { db in
            try Repository.availableForLocalWorkspaceCreation.fetchAll(db)
        }

        expectNoDifference(
            Set(repositories.map(\.id)),
            Set([
                localRepository.id,
                sharedRepository.id,
                unusedRepository.id,
            ])
        )
    }
}

private func cloudMetadata(
    workspaceID: Workspace.ID,
    projectID _: CloudWorkspaceMetadata.ID
) -> CloudWorkspaceMetadata {
    CloudWorkspaceMetadata(
        workspaceID: workspaceID,
        accountID: "account",
        lastSeenGeneration: "generation"
    )
}
