//
//  WorkspaceMutationClient.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/28/26.
//

import ConductorCloud
import Dependencies
import DependenciesMacros
import Foundation
import SharedConductorData
import Sharing
import SQLiteData

public struct WorkspaceSessionCreationResult: Equatable, Sendable {
    public let session: Session
    public let attemptID: UUID?

    public init(session: Session, attemptID: UUID?) {
        self.session = session
        self.attemptID = attemptID
    }
}

struct CloudRenameSessionRollback: Codable, Equatable, Sendable {
    let title: String?
}

struct CloudArchiveSessionRollback: Codable, Equatable, Sendable {
    let wasHidden: Bool
}

struct CloudArchiveWorkspaceRollback: Codable, Equatable, Sendable {
    let state: String?
}

struct CloudRenameWorkspaceRollback: Codable, Equatable, Sendable {
    let workspaceName: String?
    let owningFeature: CloudMutationOutcome.OwningFeature
}

@DependencyClient
public struct WorkspaceMutationClient: Sendable {
    public var archiveSession: @Sendable (
        _ route: WorkspaceMutationRoute,
        _ session: Session
    ) async throws -> Void
    public var archiveWorkspace: @Sendable (
        _ route: WorkspaceMutationRoute,
        _ canonicalWorkspaceID: Workspace.ID
    ) async throws -> Void
    public var cancelSession: @Sendable (
        _ route: WorkspaceMutationRoute,
        _ canonicalWorkspaceID: Workspace.ID,
        _ canonicalSessionID: Session.ID
    ) async throws -> Void
    public var createSession: @Sendable (
        _ route: WorkspaceMutationRoute,
        _ canonicalWorkspaceID: Workspace.ID,
        _ fallbackAgent: Session.AgentType
    ) async throws -> WorkspaceSessionCreationResult
    public var createWorkspace: @Sendable (
        _ route: WorkspaceCreationRoute,
        _ candidate: CloudWorkspaceCreationCandidate,
        _ prompt: String,
        _ model: Session.Model,
        _ reasoningEffort: Session.ReasoningEffort?
    ) async throws -> Void
    public var renameSession: @Sendable (
        _ route: WorkspaceMutationRoute,
        _ session: Session,
        _ title: String
    ) async throws -> Void
    public var renameWorkspace: @Sendable (
        _ route: WorkspaceMutationRoute,
        _ workspace: Workspace,
        _ name: String,
        _ owningFeature: CloudMutationOutcome.OwningFeature
    ) async throws -> Void
}

extension WorkspaceMutationClient: DependencyKey {
    public static var testValue: Self {
        liveValue
    }

    public static var liveValue: Self {
        Self(
            archiveSession: { route, session in
                @Dependency(\.defaultDatabase) var database
                @Dependency(\.desktopClient) var desktopClient

                switch route {
                case .desktop:
                    try await desktopClient.closeSession(
                        workspaceID: session.workspaceID,
                        sessionID: session.id
                    )
                    return

                case let .cloud(accountID, remoteWorkspaceID):
                    try await persistSessionArchive(
                        accountID: accountID,
                        remoteWorkspaceID: remoteWorkspaceID,
                        session: session,
                        database: database
                    )
                }
            },
            archiveWorkspace: { route, canonicalWorkspaceID in
                @Dependency(\.defaultDatabase) var database
                @Dependency(\.desktopClient) var desktopClient

                switch route {
                case .desktop:
                    try await desktopClient.archiveWorkspace(
                        workspaceID: canonicalWorkspaceID
                    )
                    return

                case let .cloud(accountID, remoteWorkspaceID):
                    try await persistWorkspaceArchive(
                        accountID: accountID,
                        remoteWorkspaceID: remoteWorkspaceID,
                        canonicalWorkspaceID: canonicalWorkspaceID,
                        database: database
                    )
                }
            },
            cancelSession: { route, canonicalWorkspaceID, canonicalSessionID in
                @Dependency(\.defaultDatabase) var database
                @Dependency(\.desktopClient) var desktopClient

                switch route {
                case .desktop:
                    let response = try await desktopClient.stopSession(
                        workspaceID: canonicalWorkspaceID,
                        sessionID: canonicalSessionID
                    )
                    if let response {
                        try await database.write { database in
                            if let existing = try Session
                                .find(response.id)
                                .fetchOne(database),
                               let existingUpdatedAt = existing.updatedDate,
                               let responseUpdatedAt = response.updatedDate,
                               existingUpdatedAt >= responseUpdatedAt {
                                return
                            }
                            try Session.upsert { response }.execute(database)
                        }
                    }
                    return

                case let .cloud(accountID, remoteWorkspaceID):
                    try await persistCancel(
                        accountID: accountID,
                        remoteWorkspaceID: remoteWorkspaceID,
                        canonicalSessionID: canonicalSessionID,
                        database: database
                    )
                }
            },
            createSession: {
                route,
                canonicalWorkspaceID,
                fallbackAgent in
                @Dependency(\.defaultDatabase) var database
                @Dependency(\.desktopClient) var desktopClient

                switch route {
                case .desktop:
                    let session = try await desktopClient.createSession(
                        workspaceID: canonicalWorkspaceID
                    )
                    return WorkspaceSessionCreationResult(
                        session: session,
                        attemptID: nil
                    )

                case let .cloud(accountID, remoteWorkspaceID):
                    return try await persistSessionCreation(
                        accountID: accountID,
                        remoteWorkspaceID: remoteWorkspaceID,
                        canonicalWorkspaceID: canonicalWorkspaceID,
                        fallbackAgent: fallbackAgent,
                        database: database
                    )
                }
            },
            createWorkspace: {
                route,
                candidate,
                prompt,
                model,
                reasoningEffort in
                @Dependency(\.defaultDatabase) var database

                guard case let .cloud(accountID) = route else {
                    throw WorkspaceMutationClientError.unsupportedOperation
                }
                try await persistWorkspaceCreation(
                    accountID: accountID,
                    candidate: candidate,
                    prompt: prompt,
                    model: model,
                    reasoningEffort: reasoningEffort,
                    database: database
                )
            },
            renameSession: { route, session, title in
                @Dependency(\.defaultDatabase) var database
                @Dependency(\.desktopClient) var desktopClient

                switch route {
                case .desktop:
                    try await desktopClient.renameSession(
                        workspaceID: session.workspaceID,
                        sessionID: session.id,
                        title: title
                    )
                    return

                case let .cloud(accountID, remoteWorkspaceID):
                    try await persistSessionRename(
                        accountID: accountID,
                        remoteWorkspaceID: remoteWorkspaceID,
                        session: session,
                        title: title,
                        database: database
                    )
                }
            },
            renameWorkspace: { route, workspace, name, owningFeature in
                @Dependency(\.defaultDatabase) var database

                guard case let .cloud(accountID, remoteWorkspaceID) = route else {
                    throw WorkspaceMutationClientError.unsupportedOperation
                }
                try await persistWorkspaceRename(
                    accountID: accountID,
                    remoteWorkspaceID: remoteWorkspaceID,
                    workspace: workspace,
                    name: name,
                    owningFeature: owningFeature,
                    database: database
                )
            }
        )
    }

    private static func persistSessionCreation(
        accountID: String,
        remoteWorkspaceID: String,
        canonicalWorkspaceID: Workspace.ID,
        fallbackAgent: Session.AgentType,
        database: any DatabaseWriter
    ) async throws -> WorkspaceSessionCreationResult {
        let configuration = try currentConfiguration(accountID: accountID)
        let attemptID = UUID()
        let remoteSessionID = UUID().uuidString.lowercased()
        let canonicalSessionID = CloudCanonicalID.session(
            accountID: accountID,
            remoteSessionID: remoteSessionID
        )
        let creationConfiguration = preferredCreationConfiguration(
            fallbackAgent: fallbackAgent
        )
        let now = Date()
        let session = Session(
            id: canonicalSessionID,
            workspaceID: canonicalWorkspaceID,
            title: nil,
            agentType: creationConfiguration.agent,
            isHidden: false,
            createdAt: now.ISO8601Format(),
            updatedAt: now.ISO8601Format(),
            lastUserMessageAt: nil,
            status: Session.Status(rawValue: "creating"),
            model: creationConfiguration.model
                ?? Session.Model(rawValue: ""),
            unreadCount: 0,
            freshlyCompacted: 0,
            contextTokenCount: 0,
            codexThinkingLevel: creationConfiguration.agent == .codex
                ? creationConfiguration.effort
                : nil,
            isFastModeEnabled: creationConfiguration.isFastModeEnabled,
            claudeEffortLevel: creationConfiguration.agent == .claude
                ? creationConfiguration.effort
                : nil
        )
        let request = CloudCreateSessionRequest(
            workspaceID: remoteWorkspaceID,
            sessionID: remoteSessionID,
            agent: creationConfiguration.agent.rawValue,
            model: creationConfiguration.model?.rawValue,
            effort: creationConfiguration.effort.rawValue,
            fastMode: creationConfiguration.isFastModeEnabled
        )
        try await database.write { database in
            _ = try ownedWorkspace(
                canonicalWorkspaceID: canonicalWorkspaceID,
                accountID: accountID,
                remoteWorkspaceID: remoteWorkspaceID,
                in: database
            )
            let existingMetadata = try CloudSessionMetadata
                .where { $0.workspaceID.eq(canonicalWorkspaceID) }
                .fetchAll(database)
            let attempt = try CloudPendingMutation(
                attemptID: attemptID,
                accountID: accountID,
                credentialGeneration: configuration.credentialGeneration,
                operation: .createSession,
                resourceKind: .session,
                request: request,
                canonicalWorkspaceID: canonicalWorkspaceID,
                remoteWorkspaceID: remoteWorkspaceID,
                canonicalSessionID: canonicalSessionID,
                remoteSessionID: remoteSessionID
            )
            try Session.insert { session }.execute(database)
            try CloudSessionMetadata
                .insert {
                    CloudSessionMetadata(
                        canonicalSessionID: canonicalSessionID,
                        cloudSessionID: remoteSessionID,
                        workspaceID: canonicalWorkspaceID,
                        accountID: accountID,
                        listOrder: (existingMetadata.map(\.listOrder).max() ?? -1) + 1,
                        refreshGeneration: "provisional:\(attemptID)"
                    )
                }
                .execute(database)
            try CloudPendingMutation.insert { attempt }.execute(database)
        }
        return WorkspaceSessionCreationResult(
            session: session,
            attemptID: attemptID
        )
    }

    private static func persistWorkspaceCreation(
        accountID: String,
        candidate: CloudWorkspaceCreationCandidate,
        prompt: String,
        model: Session.Model,
        reasoningEffort: Session.ReasoningEffort?,
        database: any DatabaseWriter
    ) async throws {
        let configuration = try currentConfiguration(accountID: accountID)
        guard let supported = CloudCreationConfigurationCatalog.configurations
            .first(where: {
                $0.model == model
                    && reasoningEffort.map($0.efforts.contains) != false
            }) else {
            throw WorkspaceMutationClientError.unsupportedConfiguration
        }
        let attemptID = UUID()
        // Workspace creation has no server idempotency key. A unique first
        // session name gives lost-response recovery an exact server-side
        // correlation value instead of guessing from project membership.
        let request = CloudCreateWorkspaceRequest(
            projectID: candidate.projectID,
            sessionName: "Conductor Mobile \(attemptID.uuidString.lowercased())",
            agent: supported.agent.rawValue,
            model: model.rawValue,
            effort: reasoningEffort?.rawValue
        )
        let payload = CloudWorkspaceCreationPayload(
            request: request,
            canonicalRepositoryID: candidate.repository.id,
            projectID: candidate.projectID,
            repositoryURL: candidate.repositoryURL,
            selectedModel: model,
            selectedReasoningEffort: reasoningEffort,
            prompt: prompt
        )
        let attempt = try CloudPendingMutation(
            attemptID: attemptID,
            accountID: accountID,
            credentialGeneration: configuration.credentialGeneration,
            operation: .createWorkspace,
            resourceKind: .workspace,
            request: payload
        )
        try await database.write { database in
            guard try CloudProjectRepositoryMapping
                .find(
                    CloudProjectRepositoryMapping.id(
                        accountID: accountID,
                        cloudProjectID: candidate.projectID
                    )
                )
                .fetchOne(database)?
                .canonicalRepositoryID == candidate.repository.id else {
                throw WorkspaceMutationClientError.ownershipMismatch
            }
            try CloudPendingMutation.insert { attempt }.execute(database)
        }
    }

    private static func persistWorkspaceArchive(
        accountID: String,
        remoteWorkspaceID: String,
        canonicalWorkspaceID: Workspace.ID,
        database: any DatabaseWriter
    ) async throws {
        let configuration = try currentConfiguration(accountID: accountID)
        try await database.write { database in
            _ = try ownedWorkspace(
                canonicalWorkspaceID: canonicalWorkspaceID,
                accountID: accountID,
                remoteWorkspaceID: remoteWorkspaceID,
                in: database
            )
            guard try !CloudPendingMutation.all.fetchAll(database).contains(
                where: {
                    $0.mutationOperation == .archiveWorkspace
                        && $0.canonicalWorkspaceID == canonicalWorkspaceID
                        && $0.mutationState != .acknowledged
                }
            ) else {
                throw WorkspaceMutationClientError.conflictingMutation
            }
            guard let workspace = try Workspace
                .find(canonicalWorkspaceID)
                .fetchOne(database) else {
                throw WorkspaceMutationClientError.ownershipMismatch
            }
            let rollback = try JSONEncoder.cloudMutation.encode(
                CloudArchiveWorkspaceRollback(
                    state: workspace.state?.rawValue
                )
            )
            let attempt = try CloudPendingMutation(
                accountID: accountID,
                credentialGeneration: configuration.credentialGeneration,
                operation: .archiveWorkspace,
                resourceKind: .workspace,
                request: EmptyCloudMutationPayload(),
                rollbackPayload: rollback,
                canonicalWorkspaceID: canonicalWorkspaceID,
                remoteWorkspaceID: remoteWorkspaceID
            )
            try Workspace.find(canonicalWorkspaceID)
                .update {
                    $0.state = #bind(Workspace.State(rawValue: "archived"))
                }
                .execute(database)
            try CloudPendingMutation.insert { attempt }.execute(database)
        }
    }

    private static func persistWorkspaceRename(
        accountID: String,
        remoteWorkspaceID: String,
        workspace: Workspace,
        name: String,
        owningFeature: CloudMutationOutcome.OwningFeature,
        database: any DatabaseWriter
    ) async throws {
        let configuration = try currentConfiguration(accountID: accountID)
        try await database.write { database in
            _ = try ownedWorkspace(
                canonicalWorkspaceID: workspace.id,
                accountID: accountID,
                remoteWorkspaceID: remoteWorkspaceID,
                in: database
            )
            guard try !hasUnresolvedAttempt(
                operation: .renameWorkspace,
                canonicalWorkspaceID: workspace.id,
                in: database
            ) else {
                throw WorkspaceMutationClientError.conflictingMutation
            }
            guard let persistedWorkspace = try Workspace
                .find(workspace.id)
                .fetchOne(database) else {
                throw WorkspaceMutationClientError.ownershipMismatch
            }
            let rollback = try JSONEncoder.cloudMutation.encode(
                CloudRenameWorkspaceRollback(
                    workspaceName: persistedWorkspace.workspaceName,
                    owningFeature: owningFeature
                )
            )
            let attempt = try CloudPendingMutation(
                accountID: accountID,
                credentialGeneration: configuration.credentialGeneration,
                operation: .renameWorkspace,
                resourceKind: .workspace,
                request: CloudRenameWorkspaceRequest(name: name),
                rollbackPayload: rollback,
                canonicalWorkspaceID: workspace.id,
                remoteWorkspaceID: remoteWorkspaceID
            )
            try Workspace
                .find(workspace.id)
                .update { $0.workspaceName = #bind(name) }
                .execute(database)
            try CloudPendingMutation.insert { attempt }.execute(database)
        }
    }

    private static func persistSessionRename(
        accountID: String,
        remoteWorkspaceID: String,
        session: Session,
        title: String,
        database: any DatabaseWriter
    ) async throws {
        let configuration = try currentConfiguration(accountID: accountID)
        try await database.write { database in
            let metadata = try ownedSession(
                canonicalSessionID: session.id,
                accountID: accountID,
                remoteWorkspaceID: remoteWorkspaceID,
                in: database
            )
            guard try !hasUnresolvedAttempt(
                operation: .renameSession,
                canonicalSessionID: session.id,
                in: database
            ) else {
                throw WorkspaceMutationClientError.conflictingMutation
            }
            let rollback = try JSONEncoder.cloudMutation.encode(
                CloudRenameSessionRollback(title: session.title)
            )
            let attempt = try CloudPendingMutation(
                accountID: accountID,
                credentialGeneration: configuration.credentialGeneration,
                operation: .renameSession,
                resourceKind: .session,
                request: CloudRenameSessionRequest(name: title),
                rollbackPayload: rollback,
                canonicalWorkspaceID: session.workspaceID,
                remoteWorkspaceID: remoteWorkspaceID,
                canonicalSessionID: session.id,
                remoteSessionID: metadata.cloudSessionID
            )
            try Session.find(session.id)
                .update { $0.title = #bind(title) }
                .execute(database)
            try CloudPendingMutation.insert { attempt }.execute(database)
        }
    }

    private static func persistSessionArchive(
        accountID: String,
        remoteWorkspaceID: String,
        session: Session,
        database: any DatabaseWriter
    ) async throws {
        let configuration = try currentConfiguration(accountID: accountID)
        try await database.write { database in
            let metadata = try ownedSession(
                canonicalSessionID: session.id,
                accountID: accountID,
                remoteWorkspaceID: remoteWorkspaceID,
                in: database
            )
            guard try !hasUnresolvedAttempt(
                operation: .archiveSession,
                canonicalSessionID: session.id,
                in: database
            ) else {
                throw WorkspaceMutationClientError.conflictingMutation
            }
            let rollback = try JSONEncoder.cloudMutation.encode(
                CloudArchiveSessionRollback(wasHidden: session.isHidden)
            )
            let attempt = try CloudPendingMutation(
                accountID: accountID,
                credentialGeneration: configuration.credentialGeneration,
                operation: .archiveSession,
                resourceKind: .session,
                request: EmptyCloudMutationPayload(),
                rollbackPayload: rollback,
                canonicalWorkspaceID: session.workspaceID,
                remoteWorkspaceID: remoteWorkspaceID,
                canonicalSessionID: session.id,
                remoteSessionID: metadata.cloudSessionID
            )
            try Session.find(session.id)
                .update { $0.isHidden = true }
                .execute(database)
            try CloudPendingMutation.insert { attempt }.execute(database)
        }
    }

    private static func preferredCreationConfiguration(
        fallbackAgent: Session.AgentType
    ) -> (
        agent: Session.AgentType,
        model: Session.Model?,
        effort: Session.ReasoningEffort,
        isFastModeEnabled: Bool
    ) {
        @Shared(.mobileModelSettingsOverride) var settings
        if let settings,
           let supported = CloudCreationConfigurationCatalog.configurations
            .first(where: {
                $0.model == settings.defaultModel
                    && $0.efforts.contains(settings.defaultReasoningEffort)
            }) {
            return (
                supported.agent,
                supported.model,
                settings.defaultReasoningEffort,
                settings.isFastModeEnabled && supported.supportsFastMode
            )
        }
        let agent: Session.AgentType = [.claude, .codex].contains(fallbackAgent)
            ? fallbackAgent
            : .claude
        return (agent, nil, .high, false)
    }

    private static func currentConfiguration(
        accountID: String
    ) throws -> CloudConfiguration {
        @Shared(.cloudConfiguration) var configuration
        guard let configuration,
              configuration.accountID == accountID else {
            throw WorkspaceMutationClientError.accountChanged
        }
        return configuration
    }

    private static func persistCancel(
        accountID: String,
        remoteWorkspaceID: String,
        canonicalSessionID: Session.ID,
        database: any DatabaseWriter
    ) async throws {
        @Shared(.cloudConfiguration) var configuration
        guard let configuration,
              configuration.accountID == accountID else {
            throw WorkspaceMutationClientError.accountChanged
        }
        try await database.write { db in
            let pendingMutations = try CloudPendingMutation.all.fetchAll(db)
            if pendingMutations.contains(
                where: {
                    $0.accountID == accountID
                        && $0.canonicalSessionID == canonicalSessionID
                        && $0.mutationOperation == .cancelSession
                        && (
                            $0.mutationState == .submitting
                                || $0.mutationState == .indeterminate
                        )
                }
            ) {
                return
            }
            let session = try ownedSession(
                canonicalSessionID: canonicalSessionID,
                accountID: accountID,
                remoteWorkspaceID: remoteWorkspaceID,
                in: db
            )
            let attempt = try CloudPendingMutation(
                accountID: accountID,
                credentialGeneration: configuration.credentialGeneration,
                operation: .cancelSession,
                resourceKind: .session,
                request: EmptyCloudMutationPayload(),
                canonicalWorkspaceID: session.workspaceID,
                remoteWorkspaceID: remoteWorkspaceID,
                canonicalSessionID: canonicalSessionID,
                remoteSessionID: session.cloudSessionID
            )
            try CloudPendingMutation.insert { attempt }.execute(db)
        }
    }

    private static func ownedSession(
        canonicalSessionID: Session.ID,
        accountID: String,
        remoteWorkspaceID: String,
        in database: Database
    ) throws -> CloudSessionMetadata {
        guard let session = try CloudSessionMetadata
            .find(canonicalSessionID)
            .fetchOne(database),
              session.accountID == accountID,
              let workspace = try CloudWorkspaceMetadata
                .find(session.workspaceID)
                .fetchOne(database),
              workspace.accountID == accountID,
              workspace.remoteWorkspaceID == remoteWorkspaceID else {
            throw WorkspaceMutationClientError.ownershipMismatch
        }
        return session
    }

    private static func ownedWorkspace(
        canonicalWorkspaceID: Workspace.ID,
        accountID: String,
        remoteWorkspaceID: String,
        in database: Database
    ) throws -> CloudWorkspaceMetadata {
        guard let workspace = try CloudWorkspaceMetadata
            .find(canonicalWorkspaceID)
            .fetchOne(database),
              workspace.accountID == accountID,
              workspace.remoteWorkspaceID == remoteWorkspaceID else {
            throw WorkspaceMutationClientError.ownershipMismatch
        }
        return workspace
    }

    private static func hasUnresolvedAttempt(
        operation: CloudPendingMutation.Operation,
        canonicalSessionID: Session.ID,
        in database: Database
    ) throws -> Bool {
        try CloudPendingMutation.all.fetchAll(database).contains {
            $0.mutationOperation == operation
                && $0.canonicalSessionID == canonicalSessionID
                && $0.mutationState != .acknowledged
        }
    }

    private static func hasUnresolvedAttempt(
        operation: CloudPendingMutation.Operation,
        canonicalWorkspaceID: Workspace.ID,
        in database: Database
    ) throws -> Bool {
        try CloudPendingMutation.all.fetchAll(database).contains {
            $0.mutationOperation == operation
                && $0.canonicalWorkspaceID == canonicalWorkspaceID
                && $0.mutationState != .acknowledged
        }
    }
}

public extension DependencyValues {
    var workspaceMutationClient: WorkspaceMutationClient {
        get { self[WorkspaceMutationClient.self] }
        set { self[WorkspaceMutationClient.self] = newValue }
    }
}

private struct EmptyCloudMutationPayload: Codable, Equatable, Sendable {
}

private enum WorkspaceMutationClientError: LocalizedError {
    case accountChanged
    case conflictingMutation
    case ownershipMismatch
    case unsupportedConfiguration
    case unsupportedOperation

    var errorDescription: String? {
        switch self {
        case .accountChanged:
            "The active Conductor Cloud account changed."
        case .conflictingMutation:
            "A Cloud change for this item is already pending."
        case .ownershipMismatch:
            "This Cloud chat is read-only for the current account."
        case .unsupportedConfiguration:
            "Choose a supported Cloud model and reasoning effort."
        case .unsupportedOperation:
            "This Cloud change is not available yet."
        }
    }
}
