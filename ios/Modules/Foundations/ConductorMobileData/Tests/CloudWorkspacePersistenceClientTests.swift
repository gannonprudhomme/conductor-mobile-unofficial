//
//  CloudWorkspacePersistenceClientTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/27/26.
//

import Dependencies
import SharedConductorData
@testable import ConductorMobileData
import CustomDump
import Foundation
import SQLiteData
import Testing

@Suite(.serialized)
struct CloudWorkspacePersistenceClientTests {
    @Test("Cloud responses create canonical workspace and repository rows")
    func createsCanonicalRows() async throws {
        let database = try appDatabase()

        try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            @Dependency(\.cloudWorkspacePersistenceClient) var client
            try await client.replaceCatalog(snapshot: snapshot())
            try await client.updateLifecycle(
                snapshot: CloudWorkspaceLifecycleSnapshot(
                    accountID: "account-1",
                    workspaceID: "workspace-1",
                    status: "pausing",
                    lifecycleStep: "preparing",
                    errorMessage: nil,
                    updatedAt: Date(timeIntervalSince1970: 3)
                )
            )

            let item = try await database.read {
                try WorkspaceWithRepository
                    .all(workspaceID: "workspace-1")
                    .fetchOne($0)
            }
            let unwrappedItem = try #require(item)
            #expect(unwrappedItem.workspace.workspaceName == "Cloud workspace")
            #expect(unwrappedItem.workspace.hostingServerURL == "https://api.conductor.build")
            #expect(unwrappedItem.workspace.state?.rawValue == "pausing")
            #expect(
                unwrappedItem.repository?.remoteURL
                    == "https://github.com/example/mobile.git"
            )
            #expect(unwrappedItem.cloudMetadata?.accountID == "account-1")
            #expect(unwrappedItem.cloudMetadata?.lifecycleStep == "preparing")
            #expect(unwrappedItem.isCloudOnly)
        }
    }

    @Test("Cloud refresh enriches a desktop row without clearing richer fields")
    func preservesDesktopFields() async throws {
        let database = try appDatabase()
        let repository = Repository.preview(
            id: "desktop-repository",
            name: "Desktop name",
            remoteURL: "git@github.com:example/mobile.git"
        )
        let workspace = Workspace.preview(
            id: "workspace-1",
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
        try await database.write { db in
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
        }

        try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            @Dependency(\.cloudWorkspacePersistenceClient) var client
            try await client.replaceCatalog(snapshot: snapshot())

            let item = try await database.read {
                try WorkspaceWithRepository
                    .all(workspaceID: workspace.id)
                    .fetchOne($0)
            }
            let unwrappedItem = try #require(item)
            #expect(unwrappedItem.workspace.branch == "feature/persistence")
            #expect(unwrappedItem.workspace.manualStatus == Workspace.Status.done.rawValue)
            #expect(unwrappedItem.workspace.derivedStatus == Workspace.Status.inReview.rawValue)
            #expect(unwrappedItem.workspace.pinnedAt == "2026-07-27T00:00:00Z")
            #expect(unwrappedItem.workspace.unread == 1)
            #expect(unwrappedItem.workspace.prTitle == "Desktop PR")
            #expect(unwrappedItem.workspace.prDescription == "Desktop PR description")
            #expect(unwrappedItem.repository?.id == repository.id)
            #expect(unwrappedItem.repository?.name == "Desktop name")
            #expect(unwrappedItem.isWorking)
            #expect(unwrappedItem.pullRequestStatus == .draft)
            #expect(!unwrappedItem.isCloudOnly)

            let matchingRepositories = try await database.read {
                try Repository.all.fetchAll($0).filter {
                    normalizedGitRemote($0.remoteURL ?? "")
                        == normalizedGitRemote("https://github.com/example/mobile.git")
                }
            }
            #expect(matchingRepositories.count == 1)
        }
    }

    @Test("Successful reconciliation removes only unowned Cloud rows")
    func reconcilesCatalogAndCredential() async throws {
        let database = try appDatabase()
        var firstSnapshot = snapshot()
        firstSnapshot = CloudCatalogPersistenceSnapshot(
            accountID: firstSnapshot.accountID,
            projects: firstSnapshot.projects,
            workspaces: firstSnapshot.workspaces + [
                CloudCatalogWorkspaceSnapshot(
                    id: "desktop-and-cloud",
                    projectID: "project-1",
                    name: "Shared",
                    createdAt: Date(timeIntervalSince1970: 1),
                    updatedAt: Date(timeIntervalSince1970: 2),
                    creatorID: nil,
                    deepLink: "conductor://workspace/desktop-and-cloud"
                ),
            ]
        )

        try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            @Dependency(\.cloudWorkspacePersistenceClient) var client
            try await client.replaceCatalog(snapshot: firstSnapshot)
            try await database.write { db in
                try MobileWorkspaceState
                    .insert {
                        MobileWorkspaceState(
                            workspaceID: "desktop-and-cloud",
                            isWorking: false
                        )
                    }
                    .execute(db)
            }

            try await client.replaceCatalog(
                snapshot: CloudCatalogPersistenceSnapshot(
                    accountID: "account-1",
                    projects: firstSnapshot.projects,
                    workspaces: []
                )
            )

            let removedCloudOnly = try await database.read {
                try Workspace.find("workspace-1").fetchOne($0)
            }
            let retainedDesktop = try await database.read {
                try Workspace.find("desktop-and-cloud").fetchOne($0)
            }
            let metadataCount = try await database.read {
                try CloudWorkspaceMetadata.fetchCount($0)
            }
            #expect(removedCloudOnly == nil)
            #expect(retainedDesktop != nil)
            #expect(metadataCount == 0)

            try await client.clearCachedCatalog()
            let stillRetainedDesktop = try await database.read {
                try Workspace.find("desktop-and-cloud").fetchOne($0)
            }
            #expect(stillRetainedDesktop != nil)
        }
    }
}

private func snapshot() -> CloudCatalogPersistenceSnapshot {
    CloudCatalogPersistenceSnapshot(
        accountID: "account-1",
        projects: [
            CloudCatalogProjectSnapshot(
                id: "project-1",
                name: "Mobile",
                gitRemote: "https://github.com/example/mobile.git"
            ),
        ],
        workspaces: [
            CloudCatalogWorkspaceSnapshot(
                id: "workspace-1",
                projectID: "project-1",
                name: "Cloud workspace",
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2),
                creatorID: "creator-1",
                deepLink: "conductor://workspace/workspace-1"
            ),
        ]
    )
}

private func normalizedGitRemote(_ remote: String) -> String {
    let normalized = remote
        .lowercased()
        .replacingOccurrences(of: "git@github.com:", with: "https://github.com/")
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return normalized.hasSuffix(".git")
        ? String(normalized.dropLast(4))
        : normalized
}
