//
//  CloudWorkspacePersistenceClient.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/27/26.
//

import Dependencies
import DependenciesMacros
import Foundation
import SharedConductorData
import SQLiteData

public struct CloudCatalogProjectSnapshot: Equatable, Sendable {
    public let id: String
    public let name: String
    public let gitRemote: String

    public init(id: String, name: String, gitRemote: String) {
        self.id = id
        self.name = name
        self.gitRemote = gitRemote
    }
}

public struct CloudCatalogWorkspaceSnapshot: Equatable, Sendable {
    public let id: Workspace.ID
    public let projectID: String
    public let name: String
    public let createdAt: Date
    public let updatedAt: Date
    public let creatorID: String?
    public let deepLink: String

    public init(
        id: Workspace.ID,
        projectID: String,
        name: String,
        createdAt: Date,
        updatedAt: Date,
        creatorID: String?,
        deepLink: String
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.creatorID = creatorID
        self.deepLink = deepLink
    }
}

public struct CloudCatalogPersistenceSnapshot: Equatable, Sendable {
    public let accountID: String
    public let projects: [CloudCatalogProjectSnapshot]
    public let workspaces: [CloudCatalogWorkspaceSnapshot]

    public init(
        accountID: String,
        projects: [CloudCatalogProjectSnapshot],
        workspaces: [CloudCatalogWorkspaceSnapshot]
    ) {
        self.accountID = accountID
        self.projects = projects
        self.workspaces = workspaces
    }
}

public struct CloudWorkspaceLifecycleSnapshot: Equatable, Sendable {
    public let accountID: String
    public let workspaceID: Workspace.ID
    public let status: String
    public let lifecycleStep: String?
    public let errorMessage: String?
    public let updatedAt: Date

    public init(
        accountID: String,
        workspaceID: Workspace.ID,
        status: String,
        lifecycleStep: String?,
        errorMessage: String?,
        updatedAt: Date
    ) {
        self.accountID = accountID
        self.workspaceID = workspaceID
        self.status = status
        self.lifecycleStep = lifecycleStep
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
    }
}

@DependencyClient
public struct CloudWorkspacePersistenceClient: Sendable {
    public var clearCachedCatalog: @Sendable () async throws -> Void
    public var replaceCatalog: @Sendable (
        _ snapshot: CloudCatalogPersistenceSnapshot
    ) async throws -> Void
    public var switchAccount: @Sendable (_ accountID: String) async throws -> Void
    public var updateLifecycle: @Sendable (
        _ snapshot: CloudWorkspaceLifecycleSnapshot
    ) async throws -> Void
}

extension CloudWorkspacePersistenceClient: DependencyKey {
    public static var testValue: Self { liveValue }

    public static var liveValue: Self {
        Self {
            @Dependency(\.defaultDatabase) var database
            try await database.write { db in
                try removeMetadata(
                    try CloudWorkspaceMetadata.all.fetchAll(db),
                    database: db
                )
            }
        } replaceCatalog: { snapshot in
            @Dependency(\.defaultDatabase) var database
            try await database.write { db in
                try persist(snapshot, database: db)
            }
        } switchAccount: { accountID in
            @Dependency(\.defaultDatabase) var database
            try await database.write { db in
                let staleMetadata = try CloudWorkspaceMetadata.all
                    .fetchAll(db)
                    .filter { $0.accountID != accountID }
                try removeMetadata(staleMetadata, database: db)
            }
        } updateLifecycle: { snapshot in
            @Dependency(\.defaultDatabase) var database
            try await database.write { db in
                guard let metadata = try CloudWorkspaceMetadata
                    .find(snapshot.workspaceID)
                    .fetchOne(db),
                      metadata.accountID == snapshot.accountID else {
                    return
                }

                try CloudWorkspaceMetadata
                    .find(snapshot.workspaceID)
                    .update {
                        $0.lifecycleStep = #bind(snapshot.lifecycleStep)
                        $0.lifecycleError = #bind(snapshot.errorMessage)
                        $0.lifecycleUpdatedAt = #bind(snapshot.updatedAt)
                    }
                    .execute(db)
                try Workspace
                    .find(snapshot.workspaceID)
                    .update {
                        $0.state = #bind(Workspace.State(rawValue: snapshot.status))
                    }
                    .execute(db)
            }
        }
    }

    private static func persist(
        _ snapshot: CloudCatalogPersistenceSnapshot,
        database: Database
    ) throws {
        let generation = UUID().uuidString
        let projectsByID = Dictionary(
            uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0) }
        )
        let projectIDsWithWorkspaces = Set(snapshot.workspaces.map(\.projectID))
        var repositories = try Repository.all.fetchAll(database)
        var repositoryIDsByProjectID: [String: Repository.ID] = [:]

        for project in snapshot.projects
        where projectIDsWithWorkspaces.contains(project.id) {
            let normalizedRemote = normalizedGitRemote(project.gitRemote)
            if let repository = repositories.first(where: {
                $0.remoteURL.map(normalizedGitRemote) == normalizedRemote
                    || $0.id == project.id
            }) {
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
                repositoryIDsByProjectID[project.id] = repository.id
            } else {
                let repository = Repository(
                    id: project.id,
                    createdAt: .now,
                    name: project.name,
                    remoteURL: project.gitRemote,
                    updatedAt: .now
                )
                try Repository.insert { repository }.execute(database)
                repositories.append(repository)
                repositoryIDsByProjectID[project.id] = repository.id
            }
        }

        for item in snapshot.workspaces {
            guard projectsByID[item.projectID] != nil,
                  let repositoryID = repositoryIDsByProjectID[item.projectID] else {
                continue
            }

            let existingWorkspace = try Workspace.find(item.id).fetchOne(database)
            if existingWorkspace == nil {
                try Workspace
                    .insert {
                        Workspace(
                            id: item.id,
                            createdAt: item.createdAt,
                            creatorUserID: item.creatorID,
                            hostingServerURL: CloudWorkspacePersistenceClient
                                .cloudHostingServerURL,
                            repositoryID: repositoryID,
                            updatedAt: item.updatedAt,
                            workspaceName: item.name
                        )
                    }
                    .execute(database)
            } else {
                let creatorID = existingWorkspace?.creatorUserID ?? item.creatorID
                let updatedAt = max(
                    existingWorkspace?.updatedAt ?? item.updatedAt,
                    item.updatedAt
                )
                try Workspace
                    .find(item.id)
                    .update {
                        $0.creatorUserID = #bind(creatorID)
                        $0.hostingServerURL = #bind(cloudHostingServerURL)
                        $0.repositoryID = #bind(repositoryID)
                        $0.updatedAt = #bind(updatedAt)
                        $0.workspaceName = #bind(item.name)
                    }
                    .execute(database)
            }

            let existingMetadata = try CloudWorkspaceMetadata
                .find(item.id)
                .fetchOne(database)
            try CloudWorkspaceMetadata
                .upsert {
                    CloudWorkspaceMetadata(
                        workspaceID: item.id,
                        accountID: snapshot.accountID,
                        cloudProjectID: item.projectID,
                        deepLink: item.deepLink,
                        lifecycleStep: existingMetadata?.lifecycleStep,
                        lifecycleError: existingMetadata?.lifecycleError,
                        lifecycleUpdatedAt: existingMetadata?.lifecycleUpdatedAt,
                        lastSeenGeneration: generation
                    )
                }
                .execute(database)
        }

        let staleMetadata = try CloudWorkspaceMetadata.all
            .fetchAll(database)
            .filter {
                $0.accountID != snapshot.accountID
                    || $0.lastSeenGeneration != generation
            }
        try removeMetadata(staleMetadata, database: database)
    }

    private static func removeMetadata(
        _ metadata: [CloudWorkspaceMetadata],
        database: Database
    ) throws {
        for item in metadata {
            try CloudWorkspaceMetadata.find(item.id).delete().execute(database)

            let hasDesktopObservation = try MobileWorkspaceState
                .find(item.workspaceID)
                .fetchOne(database) != nil
            let hasSessions = try Session
                .where { $0.workspaceID.eq(item.workspaceID) }
                .fetchCount(database) > 0
            guard !hasDesktopObservation, !hasSessions else {
                continue
            }
            try Workspace.find(item.workspaceID).delete().execute(database)
        }
    }

    private static func normalizedGitRemote(_ remote: String) -> String {
        let normalized = remote
            .lowercased()
            .replacingOccurrences(of: "git@github.com:", with: "https://github.com/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized.hasSuffix(".git") {
            return String(normalized.dropLast(4))
        }
        return normalized
    }

    private static let cloudHostingServerURL = "https://api.conductor.build"
}

public extension DependencyValues {
    var cloudWorkspacePersistenceClient: CloudWorkspacePersistenceClient {
        get { self[CloudWorkspacePersistenceClient.self] }
        set { self[CloudWorkspacePersistenceClient.self] = newValue }
    }
}
