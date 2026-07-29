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

    /// Persists the desktop relay snapshot while retaining any Cloud canonical identities.
    ///
    /// A Cloud-created workspace can reach the phone through both sources: the Cloud mutation
    /// response names it immediately, and the desktop relay later observes the same remote UUID.
    /// Mapping that UUID back onto the Cloud row keeps the shared list and mobile-only state from
    /// briefly containing two representations of the same workspace.
    public static func persistDesktopSnapshot(
        _ snapshot: WorkspaceListSnapshot,
        in database: Database
    ) throws {
        try Repository
            .upsert { snapshot.repositories }
            .execute(database)

        let canonicalIDsByRemoteID = Dictionary(
            try CloudWorkspaceMetadata.all
                .fetchAll(database)
                .map { ($0.remoteWorkspaceID, $0.workspaceID) },
            uniquingKeysWith: { existing, _ in existing }
        )
        let workspaces = snapshot.workspaces.map { item in
            let remoteWorkspaceID = item.workspace.id
            let canonicalWorkspaceID =
                canonicalIDsByRemoteID[remoteWorkspaceID]
                ?? remoteWorkspaceID
            return (
                remoteWorkspaceID: remoteWorkspaceID,
                workspace: item.workspace.replacingID(
                    with: canonicalWorkspaceID
                ),
                isWorking: item.isWorking,
                pullRequest: snapshot.pullRequests[remoteWorkspaceID]
            )
        }

        try persistDesktopWorkspaces(
            workspaces.map(\.workspace),
            in: database
        )

        // The desktop snapshot is authoritative for this source-specific table.
        try MobileWorkspaceState.delete().execute(database)
        try MobileWorkspaceState
            .upsert {
                workspaces.map {
                    MobileWorkspaceState(
                        workspaceID: $0.workspace.id,
                        isWorking: $0.isWorking,
                        pullRequest: $0.pullRequest
                    )
                }
            }
            .execute(database)

        for workspace in workspaces
        where workspace.remoteWorkspaceID != workspace.workspace.id {
            try Workspace.find(workspace.remoteWorkspaceID)
                .delete()
                .execute(database)
        }
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
        let desktopRepositoryIDs = try desktopRepositoryIDs(in: database)
        let mappings = try CloudProjectRepositoryMapping
            .where { $0.accountID.eq(snapshot.accountID) }
            .fetchAll(database)
        var repositoryIDs: [CloudProject.ID: Repository.ID] = [:]

        for project in snapshot.projects {
            let repository: Repository
            let matchingRepositories = matchingRepositories(
                for: project,
                in: repositories
            )
            if let existingRepository = preferredRepository(
                for: project,
                matchingRepositories: matchingRepositories,
                mappings: mappings,
                desktopRepositoryIDs: desktopRepositoryIDs
            ) {
                try consolidateRepositories(
                    matchingRepositories,
                    into: existingRepository,
                    in: database
                )
                let duplicateRepositoryIDs = Set(
                    matchingRepositories
                        .map(\.id)
                        .filter { $0 != existingRepository.id }
                )
                repositories.removeAll {
                    duplicateRepositoryIDs.contains($0.id)
                }
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

    private static func desktopRepositoryIDs(
        in database: Database
    ) throws -> Set<Repository.ID> {
        let desktopWorkspaceIDs = Set(
            try MobileWorkspaceState.all
                .fetchAll(database)
                .map(\.workspaceID)
        )
        return Set(
            try Workspace.all
                .fetchAll(database)
                .filter { desktopWorkspaceIDs.contains($0.id) }
                .compactMap(\.repositoryID)
        )
    }

    private static func matchingRepositories(
        for project: CloudProject,
        in repositories: [Repository]
    ) -> [Repository] {
        let normalizedRemote = normalizedGitRemote(project.gitRemote)
        return repositories.filter {
            $0.id == project.id
                || (
                    !normalizedRemote.isEmpty
                        && $0.remoteURL.map(normalizedGitRemote)
                            == normalizedRemote
                )
        }
    }

    private static func preferredRepository(
        for project: CloudProject,
        matchingRepositories: [Repository],
        mappings: [CloudProjectRepositoryMapping],
        desktopRepositoryIDs: Set<Repository.ID>
    ) -> Repository? {
        let desktopRepositories = matchingRepositories
            .filter { desktopRepositoryIDs.contains($0.id) }
            .sorted(by: isPreferredRepository)
        if let desktopRepository = desktopRepositories.first {
            return desktopRepository
        }
        if let mapping = mappings.first(where: {
            $0.cloudProjectID == project.id
        }),
           let mappedRepository = matchingRepositories.first(where: {
               $0.id == mapping.canonicalRepositoryID
           }) {
            return mappedRepository
        }
        return matchingRepositories.first(where: { $0.id == project.id })
            ?? matchingRepositories.sorted(by: isPreferredRepository).first
    }

    private static func isPreferredRepository(
        _ lhs: Repository,
        _ rhs: Repository
    ) -> Bool {
        let lhsHasRootPath = lhs.rootPath?.isEmpty == false
        let rhsHasRootPath = rhs.rootPath?.isEmpty == false
        if lhsHasRootPath != rhsHasRootPath {
            return lhsHasRootPath
        }
        return lhs.id < rhs.id
    }

    private static func consolidateRepositories(
        _ repositories: [Repository],
        into canonicalRepository: Repository,
        in database: Database
    ) throws {
        for repository in repositories
        where repository.id != canonicalRepository.id {
            try Workspace
                .where { $0.repositoryID.eq(repository.id) }
                .update {
                    $0.repositoryID = #bind(canonicalRepository.id)
                }
                .execute(database)
            try CloudProjectRepositoryMapping
                .where { $0.canonicalRepositoryID.eq(repository.id) }
                .update {
                    $0.canonicalRepositoryID = #bind(canonicalRepository.id)
                }
                .execute(database)
            try Repository.find(repository.id)
                .delete()
                .execute(database)
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
        try consolidateDesktopWorkspace(
            remoteWorkspaceID: workspace.id,
            into: canonicalWorkspaceID,
            in: database
        )
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
                let hasUnresolvedDelivery = try MessageDeliveryAttempt
                    .where {
                        $0.canonicalWorkspaceID.eq(canonicalWorkspaceID)
                            && $0.state.neq(
                                MessageDeliveryAttempt.State.acknowledged
                                    .rawValue
                            )
                    }
                    .fetchCount(database) > 0
                if !hasUnconsumedOutcome, !hasUnresolvedDelivery {
                    try CloudPendingMutation.find(attempt.attemptID)
                        .delete()
                        .execute(database)
                }

            default:
                break
            }
        }
    }

    private static func consolidateDesktopWorkspace(
        remoteWorkspaceID: Workspace.ID,
        into canonicalWorkspaceID: Workspace.ID,
        in database: Database
    ) throws {
        guard remoteWorkspaceID != canonicalWorkspaceID,
              let desktopWorkspace = try Workspace
                .find(remoteWorkspaceID)
                .fetchOne(database) else {
            return
        }

        try Workspace
            .upsert {
                desktopWorkspace.replacingID(with: canonicalWorkspaceID)
            }
            .execute(database)

        if let mobileState = try MobileWorkspaceState
            .find(remoteWorkspaceID)
            .fetchOne(database) {
            try MobileWorkspaceState
                .upsert {
                    MobileWorkspaceState(
                        workspaceID: canonicalWorkspaceID,
                        isWorking: mobileState.isWorking,
                        pullRequest: mobileState.pullRequestSnapshot
                    )
                }
                .execute(database)
        }

        try Workspace.find(remoteWorkspaceID)
            .delete()
            .execute(database)
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

extension Workspace {
    func replacingID(with id: ID) -> Self {
        Self(
            id: id,
            activeSessionID: activeSessionID,
            archiveCommit: archiveCommit,
            assigneeUserID: assigneeUserID,
            bigTerminalMode: bigTerminalMode,
            branch: branch,
            createdAt: createdAt,
            creatorClientID: creatorClientID,
            creatorUserID: creatorUserID,
            derivedStatus: derivedStatus,
            directoryName: directoryName,
            hostingServerURL: hostingServerURL,
            initializationFilesCopied: initializationFilesCopied,
            initializationLogPath: initializationLogPath,
            initializationParentBranch: initializationParentBranch,
            intendedTargetBranch: intendedTargetBranch,
            linkedDirectoryPaths: linkedDirectoryPaths,
            linkedWorkspaceIDs: linkedWorkspaceIDs,
            manualStatus: manualStatus,
            notes: notes,
            organizationID: organizationID,
            permissionLevel: permissionLevel,
            pinnedAt: pinnedAt,
            placeholderBranchName: placeholderBranchName,
            prDescription: prDescription,
            prTitle: prTitle,
            remoteFileSyncEnabled: remoteFileSyncEnabled,
            repositoryID: repositoryID,
            sandboxProvider: sandboxProvider,
            secondaryDirectoryName: secondaryDirectoryName,
            setupLogPath: setupLogPath,
            state: state,
            unread: unread,
            updatedAt: updatedAt,
            userSetBranchName: userSetBranchName,
            userSetWorkspaceName: userSetWorkspaceName,
            watcherUserIDs: watcherUserIDs,
            workspaceName: workspaceName,
            workspacePath: workspacePath
        )
    }
}

extension MobileWorkspaceState {
    var pullRequestSnapshot: PullRequestSnapshot? {
        guard let pullRequestURL else {
            return nil
        }
        return PullRequestSnapshot(
            url: pullRequestURL,
            isDraft: isPullRequestDraft,
            isMerged: isPullRequestMerged,
            mergeStateStatus: pullRequestMergeStateStatus,
            checksStatus: pullRequestChecksStatus
        )
    }
}
