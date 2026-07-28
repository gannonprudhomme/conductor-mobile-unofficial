//
//  CloudMutationRunner.swift
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

@DependencyClient
public struct CloudMutationRunner: Sendable {
    public var cancelAndAwait: @Sendable (
        _ accountID: String,
        _ credentialGeneration: UUID
    ) async -> Void = { _, _ in }
    public var start: @Sendable () async throws -> Void = { }
}

extension CloudMutationRunner: DependencyKey {
    public static let testValue = Self(
        cancelAndAwait: { _, _ in },
        start: { }
    )

    public static var liveValue: Self {
        Self(
            cancelAndAwait: { accountID, credentialGeneration in
                @Dependency(\.defaultDatabase) var database
                await liveActor.cancelAndAwait(
                    accountID: accountID,
                    credentialGeneration: credentialGeneration,
                    database: database
                )
            },
            start: {
                @Dependency(\.cloudAPIClient) var cloudAPIClient
                @Dependency(\.defaultDatabase) var database
                try await liveActor.start(
                    cloudAPIClient: cloudAPIClient,
                    database: database
                )
            }
        )
    }

    private static let liveActor = LiveCloudMutationRunner()
}

public extension DependencyValues {
    var cloudMutationRunner: CloudMutationRunner {
        get { self[CloudMutationRunner.self] }
        set { self[CloudMutationRunner.self] = newValue }
    }
}

private actor LiveCloudMutationRunner {
    private struct RunningAttempt {
        let accountID: String
        let credentialGeneration: UUID
        let task: Task<Void, Never>
    }

    private var claimedAttemptIDs: Set<UUID> = []
    private var isStarted = false
    private var observationTask: Task<Void, Never>?
    private var runningAttempts: [UUID: RunningAttempt] = [:]

    func start(
        cloudAPIClient: CloudAPIClient,
        database: any DatabaseWriter
    ) async throws {
        guard !isStarted else {
            return
        }
        isStarted = true

        let now = Date()
        try await database.write { database in
            let submitting = try CloudPendingMutation
                .where {
                    $0.state.eq(
                        CloudPendingMutation.State.submitting.rawValue
                    )
                }
                .fetchAll(database)
            for attempt in submitting {
                _ = try CloudPendingMutation.compareAndSetState(
                    attemptID: attempt.attemptID,
                    from: .submitting,
                    to: .indeterminate,
                    at: now,
                    in: database
                )
            }
        }

        observationTask = Task {
            @Dependency(\.continuousClock) var clock

            while !Task.isCancelled {
                await poll(
                    cloudAPIClient: cloudAPIClient,
                    database: database
                )
                do {
                    try await clock.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
        }
    }

    func cancelAndAwait(
        accountID: String,
        credentialGeneration: UUID,
        database: any DatabaseWriter
    ) async {
        let matches = runningAttempts.filter {
            $0.value.accountID == accountID
                && $0.value.credentialGeneration == credentialGeneration
        }
        for match in matches.values {
            match.task.cancel()
        }
        for match in matches {
            await match.value.task.value
            _ = try? await database.write { database in
                try CloudPendingMutation.compareAndSetState(
                    attemptID: match.key,
                    from: .submitting,
                    to: .indeterminate,
                    at: Date(),
                    in: database
                )
            }
        }
    }

    private func poll(
        cloudAPIClient: CloudAPIClient,
        database: any DatabaseWriter
    ) async {
        let attempts: [CloudPendingMutation]
        do {
            attempts = try await database.read { database in
                try CloudPendingMutation
                    .where {
                        $0.state.eq(
                            CloudPendingMutation.State.submitting.rawValue
                        )
                    }
                    .order(by: \.createdAt)
                    .fetchAll(database)
            }
        } catch {
            return
        }

        for attempt in attempts
        where claimedAttemptIDs.insert(attempt.attemptID).inserted {
            let task = Task {
                await dispatch(
                    attemptID: attempt.attemptID,
                    cloudAPIClient: cloudAPIClient,
                    database: database
                )
                didFinish(attemptID: attempt.attemptID)
            }
            runningAttempts[attempt.attemptID] = RunningAttempt(
                accountID: attempt.accountID,
                credentialGeneration: attempt.credentialGeneration,
                task: task
            )
        }
    }

    private func didFinish(attemptID: UUID) {
        runningAttempts[attemptID] = nil
    }

    private func dispatch(
        attemptID: UUID,
        cloudAPIClient: CloudAPIClient,
        database: any DatabaseWriter
    ) async {
        do {
            let attempt = try await validatedAttempt(
                attemptID: attemptID,
                database: database
            )
            if attempt.mutationOperation == .createWorkspace {
                try await dispatchWorkspaceCreation(
                    attempt,
                    cloudAPIClient: cloudAPIClient,
                    database: database
                )
                return
            }
            let didStart = try await database.write { database in
                try CloudPendingMutation.markDispatchStarted(
                    attemptID: attemptID,
                    at: Date(),
                    in: database
                )
            }
            guard didStart else {
                return
            }

            try await dispatch(
                attempt,
                cloudAPIClient: cloudAPIClient
            )
            try await transitionResponse(
                attempt: attempt,
                to: .accepted,
                database: database
            )
        } catch is CancellationError {
            await markIndeterminate(
                attemptID: attemptID,
                database: database
            )
        } catch let error as CloudAPIClientError {
            if error.isDefinitiveMutationRejection {
                await reject(
                    attemptID: attemptID,
                    error: error,
                    database: database
                )
            } else {
                await markIndeterminate(
                    attemptID: attemptID,
                    database: database
                )
            }
        } catch {
            await markIndeterminate(
                attemptID: attemptID,
                database: database
            )
        }
    }

    private func dispatchWorkspaceCreation(
        _ attempt: CloudPendingMutation,
        cloudAPIClient: CloudAPIClient,
        database: any DatabaseWriter
    ) async throws {
        let payload = try attempt.request(
            as: CloudWorkspaceCreationPayload.self
        )
        let response = try await cloudAPIClient.createWorkspaceAfterPreflight(
            expectedAccountID: attempt.accountID,
            request: payload.request
        ) { snapshot in
            guard snapshot.accountID == attempt.accountID else {
                throw CloudAPIClientError.unexpectedAccount
            }
            var preparedPayload = payload
            preparedPayload.baselineRemoteWorkspaceIDs = snapshot.workspaces
                .map(\.id)
                .sorted()
            preparedPayload.baselineCapturedAt = Date()
            let requestPayload = try JSONEncoder.cloudMutation.encode(
                preparedPayload
            )
            let current = try await self.validatedAttempt(
                attemptID: attempt.attemptID,
                database: database
            )
            guard current.credentialGeneration
                == attempt.credentialGeneration else {
                throw CancellationError()
            }
            let didPrepare = try await database.write { database in
                guard let stored = try CloudPendingMutation
                    .find(attempt.attemptID)
                    .fetchOne(database),
                      stored.mutationState == .submitting,
                      stored.credentialGeneration
                        == attempt.credentialGeneration else {
                    return false
                }
                try CloudPendingMutation
                    .find(attempt.attemptID)
                    .update {
                        $0.requestPayload = #bind(requestPayload)
                        $0.lastTransitionAt = #bind(Date())
                    }
                    .execute(database)
                return try CloudPendingMutation.markDispatchStarted(
                    attemptID: attempt.attemptID,
                    at: Date(),
                    in: database
                )
            }
            guard didPrepare else {
                throw CancellationError()
            }
        }
        try await acceptWorkspaceCreation(
            attempt: attempt,
            payload: payload,
            response: response,
            database: database
        )
    }

    private func acceptWorkspaceCreation(
        attempt: CloudPendingMutation,
        payload: CloudWorkspaceCreationPayload,
        response: CloudCreateWorkspaceResponse,
        database: any DatabaseWriter
    ) async throws {
        guard !response.workspaceID.isEmpty,
              !response.sessionID.isEmpty else {
            throw CloudAPIClientError.invalidResponse
        }
        let canonicalWorkspaceID = CloudCanonicalID.workspace(
            accountID: attempt.accountID,
            remoteWorkspaceID: response.workspaceID
        )
        let canonicalSessionID = CloudCanonicalID.session(
            accountID: attempt.accountID,
            remoteSessionID: response.sessionID
        )
        let now = Date()
        try await database.write { database in
            guard let stored = try CloudPendingMutation
                .find(attempt.attemptID)
                .fetchOne(database),
                  stored.credentialGeneration
                    == attempt.credentialGeneration,
                  stored.mutationState == .submitting else {
                return
            }
            let workspace = Workspace(
                id: canonicalWorkspaceID,
                createdAt: now,
                hostingServerURL: Workspace.conductorCloudHostingServerURL,
                repositoryID: payload.canonicalRepositoryID,
                state: Workspace.State(rawValue: "creating"),
                updatedAt: now,
                workspaceName: nil
            )
            let session = Session(
                id: canonicalSessionID,
                workspaceID: canonicalWorkspaceID,
                title: nil,
                agentType: payload.selectedModel.agentType ?? .claude,
                isHidden: false,
                createdAt: now.ISO8601Format(),
                updatedAt: now.ISO8601Format(),
                lastUserMessageAt: nil,
                status: Session.Status(rawValue: "creating"),
                model: payload.selectedModel,
                unreadCount: 0,
                freshlyCompacted: 0,
                contextTokenCount: 0,
                codexThinkingLevel: payload.selectedModel.agentType == .codex
                    ? payload.selectedReasoningEffort
                    : nil,
                isFastModeEnabled: false,
                claudeEffortLevel: payload.selectedModel.agentType == .claude
                    ? payload.selectedReasoningEffort
                    : nil
            )
            try Workspace.upsert { workspace }.execute(database)
            try CloudWorkspaceMetadata
                .upsert {
                    CloudWorkspaceMetadata(
                        workspaceID: canonicalWorkspaceID,
                        accountID: attempt.accountID,
                        remoteWorkspaceID: response.workspaceID,
                        lastSeenGeneration: "provisional:\(attempt.attemptID)"
                    )
                }
                .execute(database)
            try Session.upsert { session }.execute(database)
            try CloudSessionMetadata
                .upsert {
                    CloudSessionMetadata(
                        canonicalSessionID: canonicalSessionID,
                        cloudSessionID: response.sessionID,
                        workspaceID: canonicalWorkspaceID,
                        accountID: attempt.accountID,
                        listOrder: 0,
                        refreshGeneration: "provisional:\(attempt.attemptID)"
                    )
                }
                .execute(database)
            if !payload.prompt.isEmpty {
                try InitialPromptHandoff
                    .insert {
                        InitialPromptHandoff(
                            creationAttemptID: attempt.attemptID,
                            accountID: attempt.accountID,
                            credentialGeneration: attempt.credentialGeneration,
                            canonicalWorkspaceID: canonicalWorkspaceID,
                            remoteWorkspaceID: response.workspaceID,
                            canonicalSessionID: canonicalSessionID,
                            remoteSessionID: response.sessionID,
                            originalPrompt: payload.prompt,
                            createdAt: now
                        )
                    }
                    .execute(database)
            }
            let completionPayload = CloudWorkspaceCreationCompletionPayload(
                canonicalWorkspaceID: canonicalWorkspaceID,
                remoteWorkspaceID: response.workspaceID,
                canonicalSessionID: canonicalSessionID,
                remoteSessionID: response.sessionID,
                canonicalRepositoryID: payload.canonicalRepositoryID,
                selectedModel: payload.selectedModel,
                selectedReasoningEffort: payload.selectedReasoningEffort,
                submittedPrompt: payload.prompt
            )
            let outcome = try CloudMutationOutcome(
                attemptID: attempt.attemptID,
                accountID: attempt.accountID,
                credentialGeneration: attempt.credentialGeneration,
                owningFeature: .workspaces,
                kind: .workspaceCreationCompleted,
                payload: completionPayload,
                createdAt: now
            )
            try CloudMutationOutcome.insert { outcome }.execute(database)
            try CloudPendingMutation
                .find(attempt.attemptID)
                .update {
                    $0.canonicalWorkspaceID = #bind(canonicalWorkspaceID)
                    $0.remoteWorkspaceID = #bind(response.workspaceID)
                    $0.canonicalSessionID = #bind(canonicalSessionID)
                    $0.remoteSessionID = #bind(response.sessionID)
                    $0.state = #bind(
                        CloudPendingMutation.State.accepted.rawValue
                    )
                    $0.lastTransitionAt = #bind(now)
                }
                .execute(database)
        }
    }

    private func validatedAttempt(
        attemptID: UUID,
        database: any DatabaseReader
    ) async throws -> CloudPendingMutation {
        let attempt = try await database.read { database in
            try CloudPendingMutation.find(attemptID).fetchOne(database)
        }
        guard let attempt,
              attempt.mutationState == .submitting else {
            throw CancellationError()
        }

        @Shared(.cloudConfiguration) var cloudConfiguration
        guard cloudConfiguration?.accountID == attempt.accountID,
              cloudConfiguration?.credentialGeneration
                == attempt.credentialGeneration else {
            throw CancellationError()
        }
        return attempt
    }

    private func dispatch(
        _ attempt: CloudPendingMutation,
        cloudAPIClient: CloudAPIClient
    ) async throws {
        switch attempt.mutationOperation {
        case .sendMessage:
            let sessionID = try required(attempt.remoteSessionID)
            let response = try await cloudAPIClient.sendMessage(
                expectedAccountID: attempt.accountID,
                sessionID: sessionID,
                request: attempt.request(as: CloudSendMessageRequest.self)
            )
            guard response.messageID == attempt.stableRemoteMessageID,
                  response.state == .queued || response.state == .sent else {
                throw CloudAPIClientError.invalidResponse
            }

        case .cancelSession:
            let sessionID = try required(attempt.remoteSessionID)
            let response = try await cloudAPIClient.cancelSession(
                expectedAccountID: attempt.accountID,
                sessionID: sessionID
            )
            guard response.sessionID == sessionID,
                  attempt.remoteWorkspaceID == nil
                    || response.workspaceID == attempt.remoteWorkspaceID else {
                throw CloudAPIClientError.invalidResponse
            }

        case .createSession:
            let request = try attempt.request(
                as: CloudCreateSessionRequest.self
            )
            let response = try await cloudAPIClient.createSession(
                expectedAccountID: attempt.accountID,
                request: request
            )
            guard CloudCanonicalID.session(
                accountID: attempt.accountID,
                remoteSessionID: response.id
            ) == CloudCanonicalID.session(
                accountID: attempt.accountID,
                remoteSessionID: request.sessionID
            ) else {
                throw CloudAPIClientError.invalidResponse
            }

        case .renameSession:
            let sessionID = try required(attempt.remoteSessionID)
            let response = try await cloudAPIClient.renameSession(
                expectedAccountID: attempt.accountID,
                sessionID: sessionID,
                request: attempt.request(
                    as: CloudRenameSessionRequest.self
                )
            )
            guard response.id == sessionID else {
                throw CloudAPIClientError.invalidResponse
            }

        case .archiveSession:
            let sessionID = try required(attempt.remoteSessionID)
            let response = try await cloudAPIClient.archiveSession(
                expectedAccountID: attempt.accountID,
                sessionID: sessionID
            )
            guard response.sessionID == sessionID,
                  attempt.remoteWorkspaceID == nil
                    || response.workspaceID == attempt.remoteWorkspaceID else {
                throw CloudAPIClientError.invalidResponse
            }

        case .archiveWorkspace:
            let workspaceID = try required(attempt.remoteWorkspaceID)
            let response = try await cloudAPIClient.archiveWorkspace(
                expectedAccountID: attempt.accountID,
                workspaceID: workspaceID
            )
            guard response.workspaceID == workspaceID else {
                throw CloudAPIClientError.invalidResponse
            }

        default:
            throw CloudAPIClientError.invalidResponse
        }
    }

    private func transitionResponse(
        attempt: CloudPendingMutation,
        to destination: CloudPendingMutation.State,
        database: any DatabaseWriter
    ) async throws {
        try await database.write { database in
            guard let stored = try CloudPendingMutation
                .find(attempt.attemptID)
                .fetchOne(database),
                  stored.credentialGeneration
                    == attempt.credentialGeneration else {
                return
            }
            _ = try CloudPendingMutation.compareAndSetState(
                attemptID: attempt.attemptID,
                from: stored.mutationState,
                to: destination,
                at: Date(),
                in: database
            )
        }
    }

    private func markIndeterminate(
        attemptID: UUID,
        database: any DatabaseWriter
    ) async {
        _ = try? await database.write { database in
            try CloudPendingMutation.compareAndSetState(
                attemptID: attemptID,
                from: .submitting,
                to: .indeterminate,
                at: Date(),
                in: database
            )
        }
    }

    private func reject(
        attemptID: UUID,
        error: CloudAPIClientError,
        database: any DatabaseWriter
    ) async {
        _ = try? await database.write { database in
            guard let attempt = try CloudPendingMutation
                .find(attemptID)
                .fetchOne(database),
                  attempt.mutationState == .submitting else {
                return
            }
            try Self.rollback(attempt, in: database)
            let owner = if attempt.mutationOperation == .sendMessage,
                let sessionID = attempt.canonicalSessionID {
                CloudMutationOutcome.OwningFeature.chat(
                    sessionID: sessionID
                )
            } else if attempt.mutationOperation == .createWorkspace
                || attempt.mutationOperation == .archiveWorkspace {
                CloudMutationOutcome.OwningFeature.workspaces
            } else if let workspaceID = attempt.canonicalWorkspaceID {
                CloudMutationOutcome.OwningFeature.workspaceChat(
                    workspaceID: workspaceID
                )
            } else {
                CloudMutationOutcome.OwningFeature.workspaces
            }
            let outcome = try CloudMutationOutcome(
                attemptID: attemptID,
                accountID: attempt.accountID,
                credentialGeneration: attempt.credentialGeneration,
                owningFeature: owner,
                kind: .rejectedMutation,
                payload: CloudMutationRejectionPayload(
                    title: "Cloud change failed",
                    message: error.localizedDescription,
                    operation: attempt.operation,
                    canonicalWorkspaceID: attempt.canonicalWorkspaceID,
                    canonicalSessionID: attempt.canonicalSessionID
                )
            )
            try CloudMutationOutcome.insert { outcome }.execute(database)
            try CloudPendingMutation.find(attemptID).delete().execute(database)
        }
    }

    private nonisolated static func rollback(
        _ attempt: CloudPendingMutation,
        in database: Database
    ) throws {
        switch attempt.mutationOperation {
        case .createSession:
            if let canonicalSessionID = attempt.canonicalSessionID {
                try CloudSessionMetadata
                    .find(canonicalSessionID)
                    .delete()
                    .execute(database)
                try Session
                    .find(canonicalSessionID)
                    .delete()
                    .execute(database)
            }

        case .renameSession:
            if let canonicalSessionID = attempt.canonicalSessionID,
               let rollback = try attempt.rollback(
                as: CloudRenameSessionRollback.self
               ) {
                try Session
                    .find(canonicalSessionID)
                    .update { $0.title = #bind(rollback.title) }
                    .execute(database)
            }

        case .archiveSession:
            if let canonicalSessionID = attempt.canonicalSessionID,
               let rollback = try attempt.rollback(
                as: CloudArchiveSessionRollback.self
               ) {
                try Session
                    .find(canonicalSessionID)
                    .update {
                        $0.isHidden = #bind(rollback.wasHidden)
                    }
                    .execute(database)
            }

        case .archiveWorkspace:
            if let canonicalWorkspaceID = attempt.canonicalWorkspaceID,
               let rollback = try attempt.rollback(
                as: CloudArchiveWorkspaceRollback.self
               ) {
                try Workspace
                    .find(canonicalWorkspaceID)
                    .update {
                        $0.state = #bind(
                            rollback.state.map(Workspace.State.init(rawValue:))
                        )
                    }
                    .execute(database)
            }

        default:
            break
        }
    }

    private func required(_ value: String?) throws -> String {
        guard let value else {
            throw CloudAPIClientError.invalidResponse
        }
        return value
    }
}

private extension CloudAPIClientError {
    var isDefinitiveMutationRejection: Bool {
        guard case let .requestFailed(statusCode, error) = self else {
            return self == .unexpectedAccount
        }
        if error?.retryable == true || (500..<600).contains(statusCode) {
            return false
        }
        return (400..<500).contains(statusCode)
    }
}
