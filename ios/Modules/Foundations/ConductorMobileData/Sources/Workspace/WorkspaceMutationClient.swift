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

public enum WorkspaceMutationResult: Equatable, Sendable {
    case desktop(message: Message?)
    case cloud(attemptID: UUID)
}

public struct WorkspaceSessionCreationResult: Equatable, Sendable {
    public let session: Session
    public let attemptID: UUID?

    public init(session: Session, attemptID: UUID?) {
        self.session = session
        self.attemptID = attemptID
    }
}

public struct CloudSendDraftRollback: Codable, Equatable, Sendable {
    public let submittedDraft: String

    public init(submittedDraft: String) {
        self.submittedDraft = submittedDraft
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

@DependencyClient
public struct WorkspaceMutationClient: Sendable {
    public var archiveSession: @Sendable (
        _ route: WorkspaceMutationRoute,
        _ session: Session
    ) async throws -> WorkspaceMutationResult
    public var archiveWorkspace: @Sendable (
        _ route: WorkspaceMutationRoute,
        _ canonicalWorkspaceID: Workspace.ID
    ) async throws -> WorkspaceMutationResult
    public var cancelSession: @Sendable (
        _ route: WorkspaceMutationRoute,
        _ canonicalWorkspaceID: Workspace.ID,
        _ canonicalSessionID: Session.ID
    ) async throws -> WorkspaceMutationResult
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
    ) async throws -> WorkspaceMutationResult
    public var renameSession: @Sendable (
        _ route: WorkspaceMutationRoute,
        _ session: Session,
        _ title: String
    ) async throws -> WorkspaceMutationResult
    public var sendMessage: @Sendable (
        _ route: WorkspaceMutationRoute,
        _ canonicalWorkspaceID: Workspace.ID,
        _ canonicalSessionID: Session.ID,
        _ submittedDraft: String,
        _ message: String,
        _ model: Session.Model,
        _ isFastModeEnabled: Bool,
        _ mode: MessageSendMode,
        _ reasoningEffort: Session.ReasoningEffort?
    ) async throws -> WorkspaceMutationResult
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
                    return .desktop(message: nil)

                case let .cloud(accountID, remoteWorkspaceID):
                    return try await persistSessionArchive(
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
                    return .desktop(message: nil)

                case let .cloud(accountID, remoteWorkspaceID):
                    return try await persistWorkspaceArchive(
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
                    return .desktop(message: nil)

                case let .cloud(accountID, remoteWorkspaceID):
                    return try await persistCancel(
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
                return try await persistWorkspaceCreation(
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
                    return .desktop(message: nil)

                case let .cloud(accountID, remoteWorkspaceID):
                    return try await persistSessionRename(
                        accountID: accountID,
                        remoteWorkspaceID: remoteWorkspaceID,
                        session: session,
                        title: title,
                        database: database
                    )
                }
            },
            sendMessage: {
                route,
                canonicalWorkspaceID,
                canonicalSessionID,
                submittedDraft,
                message,
                model,
                isFastModeEnabled,
                mode,
                reasoningEffort in
                @Dependency(\.defaultDatabase) var database
                @Dependency(\.desktopClient) var desktopClient

                switch route {
                case .desktop:
                    let response = try await desktopClient.sendMessage(
                        workspaceID: canonicalWorkspaceID,
                        sessionID: canonicalSessionID,
                        message: message,
                        model: model,
                        isFastModeEnabled: isFastModeEnabled,
                        mode: mode,
                        reasoningEffort: reasoningEffort
                    )
                    return .desktop(message: response)

                case let .cloud(accountID, remoteWorkspaceID):
                    return try await persistSend(
                        accountID: accountID,
                        remoteWorkspaceID: remoteWorkspaceID,
                        canonicalSessionID: canonicalSessionID,
                        submittedDraft: submittedDraft,
                        message: message,
                        database: database
                    )
                }
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
        let remoteSessionID = UUID().uuidString
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
            isFastModeEnabled: nil,
            claudeEffortLevel: creationConfiguration.agent == .claude
                ? creationConfiguration.effort
                : nil
        )
        let request = CloudCreateSessionRequest(
            workspaceID: remoteWorkspaceID,
            sessionID: remoteSessionID,
            agent: creationConfiguration.agent.rawValue,
            model: creationConfiguration.model?.rawValue,
            effort: creationConfiguration.effort?.rawValue
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
    ) async throws -> WorkspaceMutationResult {
        let configuration = try currentConfiguration(accountID: accountID)
        guard let supported = CloudCreationConfigurationCatalog.configurations
            .first(where: {
                $0.model == model
                    && reasoningEffort.map($0.efforts.contains) != false
            }) else {
            throw WorkspaceMutationClientError.unsupportedConfiguration
        }
        let request = CloudCreateWorkspaceRequest(
            projectID: candidate.projectID,
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
        return .cloud(attemptID: attempt.attemptID)
    }

    private static func persistWorkspaceArchive(
        accountID: String,
        remoteWorkspaceID: String,
        canonicalWorkspaceID: Workspace.ID,
        database: any DatabaseWriter
    ) async throws -> WorkspaceMutationResult {
        let configuration = try currentConfiguration(accountID: accountID)
        return try await database.write { database in
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
            return .cloud(attemptID: attempt.attemptID)
        }
    }

    private static func persistSessionRename(
        accountID: String,
        remoteWorkspaceID: String,
        session: Session,
        title: String,
        database: any DatabaseWriter
    ) async throws -> WorkspaceMutationResult {
        let configuration = try currentConfiguration(accountID: accountID)
        return try await database.write { database in
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
            return .cloud(attemptID: attempt.attemptID)
        }
    }

    private static func persistSessionArchive(
        accountID: String,
        remoteWorkspaceID: String,
        session: Session,
        database: any DatabaseWriter
    ) async throws -> WorkspaceMutationResult {
        let configuration = try currentConfiguration(accountID: accountID)
        return try await database.write { database in
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
            return .cloud(attemptID: attempt.attemptID)
        }
    }

    private static func preferredCreationConfiguration(
        fallbackAgent: Session.AgentType
    ) -> (
        agent: Session.AgentType,
        model: Session.Model?,
        effort: Session.ReasoningEffort?
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
                settings.defaultReasoningEffort
            )
        }
        let agent: Session.AgentType = [.claude, .codex].contains(fallbackAgent)
            ? fallbackAgent
            : .claude
        return (agent, nil, nil)
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

    private static func persistSend(
        accountID: String,
        remoteWorkspaceID: String,
        canonicalSessionID: Session.ID,
        submittedDraft: String,
        message: String,
        database: any DatabaseWriter
    ) async throws -> WorkspaceMutationResult {
        @Shared(.cloudConfiguration) var configuration
        guard let configuration,
              configuration.accountID == accountID else {
            throw WorkspaceMutationClientError.accountChanged
        }
        let attemptID = UUID()
        let stableMessageID = UUID().uuidString
        let rollbackPayload = try JSONEncoder.cloudMutation.encode(
            CloudSendDraftRollback(submittedDraft: submittedDraft)
        )
        try await database.write { database in
            let session = try ownedSession(
                canonicalSessionID: canonicalSessionID,
                accountID: accountID,
                remoteWorkspaceID: remoteWorkspaceID,
                in: database
            )
            let attempt = try CloudPendingMutation(
                attemptID: attemptID,
                accountID: accountID,
                credentialGeneration: configuration.credentialGeneration,
                operation: .sendMessage,
                resourceKind: .message,
                request: CloudSendMessageRequest(
                    messageID: stableMessageID,
                    message: message
                ),
                rollbackPayload: rollbackPayload,
                canonicalWorkspaceID: session.workspaceID,
                remoteWorkspaceID: remoteWorkspaceID,
                canonicalSessionID: canonicalSessionID,
                remoteSessionID: session.cloudSessionID,
                stableRemoteMessageID: stableMessageID
            )
            try CloudPendingMutation.insert { attempt }.execute(database)
        }
        return .cloud(attemptID: attemptID)
    }

    private static func persistCancel(
        accountID: String,
        remoteWorkspaceID: String,
        canonicalSessionID: Session.ID,
        database: any DatabaseWriter
    ) async throws -> WorkspaceMutationResult {
        @Shared(.cloudConfiguration) var configuration
        guard let configuration,
              configuration.accountID == accountID else {
            throw WorkspaceMutationClientError.accountChanged
        }
        return try await database.write { db in
            let pendingMutations = try CloudPendingMutation.all.fetchAll(db)
            if let existing = pendingMutations.first(
                where: {
                    $0.accountID == accountID
                        && $0.canonicalSessionID == canonicalSessionID
                        && $0.mutationOperation == .cancelSession
                        && $0.mutationState != .acknowledged
                }
            ) {
                return .cloud(attemptID: existing.attemptID)
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
            return .cloud(attemptID: attempt.attemptID)
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
            "A Cloud change for this chat is already pending."
        case .ownershipMismatch:
            "This Cloud chat is read-only for the current account."
        case .unsupportedConfiguration:
            "Choose a supported Cloud model and reasoning effort."
        case .unsupportedOperation:
            "This Cloud change is not available yet."
        }
    }
}
