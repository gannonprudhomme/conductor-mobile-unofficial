//
//  CloudWorkspacePersistence.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/27/26.
//

import ConductorCloud
import Foundation
import SharedConductorData
import SQLiteData

public enum CloudWorkspacePersistence {
    /// Persists a Desktop workspace snapshot without allowing it to replace Cloud-owned fields.
    ///
    /// Desktop remains authoritative for its enrichment fields, including branch, pull-request,
    /// pin, unread, and local workspace details. Once Cloud metadata owns the canonical row,
    /// however, snapshot arrival order must not change its Cloud identity or lifecycle.
    public static func persistDesktopWorkspaces(
        _ workspaces: [Workspace],
        in database: Database
    ) throws {
        for desktopWorkspace in workspaces {
            guard try CloudWorkspaceMetadata
                .find(desktopWorkspace.id)
                .fetchOne(database) != nil,
                  let cloudWorkspace = try Workspace
                    .find(desktopWorkspace.id)
                    .fetchOne(database) else {
                try Workspace.upsert { desktopWorkspace }.execute(database)
                continue
            }

            var mergedWorkspace = desktopWorkspace
            mergedWorkspace.createdAt = cloudWorkspace.createdAt
            mergedWorkspace.creatorUserID = cloudWorkspace.creatorUserID
            mergedWorkspace.hostingServerURL = cloudWorkspace.hostingServerURL
            mergedWorkspace.repositoryID = cloudWorkspace.repositoryID
            mergedWorkspace.state = cloudWorkspace.state
            mergedWorkspace.updatedAt = cloudWorkspace.updatedAt
            mergedWorkspace.workspaceName = cloudWorkspace.workspaceName
            try Workspace.upsert { mergedWorkspace }.execute(database)
        }
    }

    public static func persist(
        _ snapshot: CloudWorkspaceSnapshot,
        in database: Database
    ) throws {
        let generation = UUID().uuidString
        let repositoryIDs = try repositoryIDsByProjectID(
            for: snapshot,
            generation: generation,
            in: database
        )
        try persistWorkspaces(
            from: snapshot,
            repositoryIDsByProjectID: repositoryIDs,
            generation: generation,
            in: database
        )
        try removeStaleCloudRows(
            currentAccountID: snapshot.accountID,
            generation: generation,
            from: database
        )
        try removeStaleProjectMappings(
            currentAccountID: snapshot.accountID,
            generation: generation,
            from: database
        )
    }

    /// Maps API projects onto canonical repositories, preferring an existing repository with the
    /// same ID or normalized Git remote. This prevents duplicate project sections when desktop
    /// and Cloud observe the same repository.
    private static func repositoryIDsByProjectID(
        for snapshot: CloudWorkspaceSnapshot,
        generation: String,
        in database: Database
    ) throws -> [CloudProject.ID: Repository.ID] {
        var repositories = try Repository.all.fetchAll(database)
        let mappings = try CloudProjectRepositoryMapping
            .where { $0.accountID.eq(snapshot.accountID) }
            .fetchAll(database)
        var repositoryIDs: [CloudProject.ID: Repository.ID] = [:]

        for project in snapshot.projects {
            let repository: Repository
            if let mapping = mappings.first(where: {
                $0.cloudProjectID == project.id
            }),
               let existingRepository = repositories.first(where: {
                   $0.id == mapping.canonicalRepositoryID
               }) {
                try fillMissingRepositoryDetails(
                    from: project,
                    in: existingRepository,
                    database: database
                )
                repository = existingRepository
            } else if let existingRepository = matchingRepository(
                for: project,
                in: repositories
            ) {
                try fillMissingRepositoryDetails(
                    from: project,
                    in: existingRepository,
                    database: database
                )
                repository = existingRepository
            } else {
                repository = try insertRepository(
                    for: project,
                    in: database
                )
                repositories.append(repository)
            }
            repositoryIDs[project.id] = repository.id
            try CloudProjectRepositoryMapping
                .upsert {
                    CloudProjectRepositoryMapping(
                        accountID: snapshot.accountID,
                        cloudProjectID: project.id,
                        canonicalRepositoryID: repository.id,
                        projectName: project.name,
                        gitRemote: project.gitRemote,
                        refreshGeneration: generation
                    )
                }
                .execute(database)
        }

        return repositoryIDs
    }

    private static func matchingRepository(
        for project: CloudProject,
        in repositories: [Repository]
    ) -> Repository? {
        let normalizedRemote = normalizedGitRemote(project.gitRemote)
        return repositories.first {
            $0.id == project.id
                || (
                    !normalizedRemote.isEmpty
                        && $0.remoteURL.map(normalizedGitRemote)
                            == normalizedRemote
                )
        }
    }

    /// Cloud fills gaps in repository presentation data but never replaces richer desktop data.
    private static func fillMissingRepositoryDetails(
        from project: CloudProject,
        in repository: Repository,
        database: Database
    ) throws {
        let name = repository.name?.isEmpty == false
            ? repository.name
            : project.name
        let remoteURL = repository.remoteURL?.isEmpty == false
            ? repository.remoteURL
            : project.gitRemote
        try Repository
            .find(repository.id)
            .update {
                $0.name = #bind(name)
                $0.remoteURL = #bind(remoteURL)
            }
            .execute(database)
    }

    private static func insertRepository(
        for project: CloudProject,
        in database: Database
    ) throws -> Repository {
        let repository = Repository(
            id: project.id,
            createdAt: .now,
            name: project.name,
            remoteURL: project.gitRemote,
            updatedAt: .now
        )
        try Repository.insert { repository }.execute(database)
        return repository
    }

    /// Persists each API workspace into the same canonical table read by the local workspace UI.
    /// A workspace is ignored if its project was absent from the current projects page.
    private static func persistWorkspaces(
        from snapshot: CloudWorkspaceSnapshot,
        repositoryIDsByProjectID: [CloudProject.ID: Repository.ID],
        generation: String,
        in database: Database
    ) throws {
        let projectIDs = Set(snapshot.projects.map(\.id))
        for item in snapshot.workspaces {
            guard projectIDs.contains(item.project.id),
                  snapshot.statuses[item.id]?.status != .deleted,
                  let repositoryID = repositoryIDsByProjectID[item.project.id]
            else {
                continue
            }

            try persistWorkspace(
                item,
                accountID: snapshot.accountID,
                status: snapshot.statuses[item.id],
                repositoryID: repositoryID,
                generation: generation,
                in: database
            )
        }
    }

    private static func persistWorkspace(
        _ item: CloudProjectWorkspace,
        accountID: String,
        status: CloudWorkspaceStatusResponse?,
        repositoryID: Repository.ID,
        generation: String,
        in database: Database
    ) throws {
        let workspace = item.workspace
        let existingMetadata = try CloudWorkspaceMetadata
            .where {
                $0.accountID.eq(accountID)
                    && $0.remoteWorkspaceID.eq(workspace.id)
            }
            .fetchOne(database)
        let canonicalWorkspaceID = existingMetadata?.workspaceID ?? workspace.id
        let existingWorkspace = try Workspace
            .find(canonicalWorkspaceID)
            .fetchOne(database)

        if let existingWorkspace {
            try updateCloudWorkspace(
                existingWorkspace,
                from: workspace,
                status: status,
                repositoryID: repositoryID,
                in: database
            )
        } else {
            try insertAPIOnlyWorkspace(
                workspace,
                canonicalWorkspaceID: canonicalWorkspaceID,
                status: status,
                repositoryID: repositoryID,
                in: database
            )
        }

        try upsertCloudMetadata(
            for: item,
            canonicalWorkspaceID: canonicalWorkspaceID,
            accountID: accountID,
            generation: generation,
            in: database
        )
        try reconcileWorkspaceAttempts(
            canonicalWorkspaceID: canonicalWorkspaceID,
            isAuthoritativelyArchived: status?.status == .archived,
            in: database
        )
    }

    private static func insertAPIOnlyWorkspace(
        _ workspace: CloudWorkspace,
        canonicalWorkspaceID: Workspace.ID,
        status: CloudWorkspaceStatusResponse?,
        repositoryID: Repository.ID,
        in database: Database
    ) throws {
        try Workspace
            .insert {
                Workspace(
                    id: canonicalWorkspaceID,
                    createdAt: workspace.createdAt,
                    creatorUserID: workspace.creatorID,
                    hostingServerURL: Workspace.conductorCloudHostingServerURL,
                    repositoryID: repositoryID,
                    state: status.map {
                        Workspace.State(rawValue: $0.status.rawValue)
                    },
                    updatedAt: workspace.lastActivityAt ?? workspace.createdAt,
                    workspaceName: workspace.name
                )
            }
            .execute(database)
    }

    private static func updateCloudWorkspace(
        _ existingWorkspace: Workspace,
        from workspace: CloudWorkspace,
        status: CloudWorkspaceStatusResponse?,
        repositoryID: Repository.ID,
        in database: Database
    ) throws {
        let state = status.map {
            Workspace.State(rawValue: $0.status.rawValue)
        } ?? existingWorkspace.state
        try Workspace
            .find(existingWorkspace.id)
            .update {
                $0.createdAt = #bind(workspace.createdAt)
                $0.creatorUserID = #bind(workspace.creatorID)
                $0.hostingServerURL = #bind(
                    Workspace.conductorCloudHostingServerURL
                )
                $0.repositoryID = #bind(repositoryID)
                $0.state = #bind(state)
                $0.updatedAt = #bind(
                    workspace.lastActivityAt ?? workspace.createdAt
                )
                $0.workspaceName = #bind(workspace.name)
            }
            .execute(database)
    }

    private static func upsertCloudMetadata(
        for item: CloudProjectWorkspace,
        canonicalWorkspaceID: Workspace.ID,
        accountID: String,
        generation: String,
        in database: Database
    ) throws {
        let workspace = item.workspace
        try CloudWorkspaceMetadata
            .upsert {
                    CloudWorkspaceMetadata(
                    workspaceID: canonicalWorkspaceID,
                    accountID: accountID,
                    remoteWorkspaceID: workspace.id,
                    lastSeenGeneration: generation
                )
            }
            .execute(database)
    }

    private static func reconcileWorkspaceAttempts(
        canonicalWorkspaceID: Workspace.ID,
        isAuthoritativelyArchived: Bool,
        in database: Database
    ) throws {
        let attempts = try CloudPendingMutation
            .where {
                $0.canonicalWorkspaceID.eq(canonicalWorkspaceID)
            }
            .fetchAll(database)
        for attempt in attempts {
            switch attempt.mutationOperation {
            case .archiveWorkspace:
                if isAuthoritativelyArchived {
                    try CloudPendingMutation.find(attempt.attemptID)
                        .delete()
                        .execute(database)
                    try CloudOwnershipCleanup.perform(
                        scope: .workspaces([canonicalWorkspaceID]),
                        reason: .authoritativeSnapshot,
                        in: database
                    )
                    continue
                }
                try Workspace.find(canonicalWorkspaceID)
                    .update {
                        $0.state = #bind(
                            Workspace.State(rawValue: "archived")
                        )
                    }
                    .execute(database)

            case .createWorkspace:
                _ = try CloudPendingMutation.compareAndSetState(
                    attemptID: attempt.attemptID,
                    from: attempt.mutationState,
                    to: .acknowledged,
                    at: Date(),
                    in: database
                )
                let hasUnconsumedOutcome = try CloudMutationOutcome
                    .where {
                        $0.attemptID.eq(attempt.attemptID)
                            && $0.consumedAt.is(nil)
                    }
                    .fetchCount(database) > 0
                let hasUnresolvedHandoff = try InitialPromptHandoff
                    .where {
                        $0.creationAttemptID.eq(attempt.attemptID)
                            && $0.state.neq(
                                InitialPromptHandoff.State.resolved.rawValue
                            )
                    }
                    .fetchCount(database) > 0
                if !hasUnconsumedOutcome, !hasUnresolvedHandoff {
                    try CloudPendingMutation.find(attempt.attemptID)
                        .delete()
                        .execute(database)
                }

            default:
                break
            }
        }
    }

    /// Removes ownership not seen in this completed snapshot. The metadata helper retains
    /// canonical workspaces that are still desktop-observed or have sessions.
    private static func removeStaleCloudRows(
        currentAccountID: String,
        generation: String,
        from database: Database
    ) throws {
        let staleMetadata = try CloudWorkspaceMetadata
            .where {
                $0.accountID.neq(currentAccountID)
                    || $0.lastSeenGeneration.neq(generation)
            }
            .fetchAll(database)
        try CloudWorkspaceMetadata.removeCachedRows(
            staleMetadata,
            from: database
        )
    }

    private static func removeStaleProjectMappings(
        currentAccountID: String,
        generation: String,
        from database: Database
    ) throws {
        try CloudProjectRepositoryMapping
            .where {
                $0.accountID.neq(currentAccountID)
                    || $0.refreshGeneration.neq(generation)
            }
            .delete()
            .execute(database)
    }

    public static func normalizedGitRemote(_ remote: String) -> String {
        let normalized = remote
            .lowercased()
            .replacingOccurrences(
                of: "git@github.com:",
                with: "https://github.com/"
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized.hasSuffix(".git") {
            return String(normalized.dropLast(4))
        }
        return normalized
    }
}
