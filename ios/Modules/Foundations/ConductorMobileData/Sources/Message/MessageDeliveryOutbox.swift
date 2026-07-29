//
//  MessageDeliveryOutbox.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/29/26.
//

import ConductorCloud
import Dependencies
import DependenciesMacros
import Foundation
import SharedConductorData
import Sharing
import SQLiteData

public struct MessageDeliveryRequest: Equatable, Sendable {
    public let route: WorkspaceMutationRoute
    public let canonicalWorkspaceID: Workspace.ID
    public let canonicalSessionID: Session.ID
    public let content: String
    public let model: Session.Model
    public let isFastModeEnabled: Bool
    public let mode: MessageSendMode
    public let reasoningEffort: Session.ReasoningEffort?
    public let submittedDraft: String
    public let previousTurnID: String?

    public init(
        route: WorkspaceMutationRoute,
        canonicalWorkspaceID: Workspace.ID,
        canonicalSessionID: Session.ID,
        content: String,
        model: Session.Model,
        isFastModeEnabled: Bool,
        mode: MessageSendMode,
        reasoningEffort: Session.ReasoningEffort?,
        submittedDraft: String,
        previousTurnID: String?
    ) {
        self.route = route
        self.canonicalWorkspaceID = canonicalWorkspaceID
        self.canonicalSessionID = canonicalSessionID
        self.content = content
        self.model = model
        self.isFastModeEnabled = isFastModeEnabled
        self.mode = mode
        self.reasoningEffort = reasoningEffort
        self.submittedDraft = submittedDraft
        self.previousTurnID = previousTurnID
    }
}

@DependencyClient
public struct MessageDeliveryOutbox: Sendable {
    public var cancelAndAwait: @Sendable (
        _ accountID: String,
        _ credentialGeneration: UUID
    ) async -> Void = { _, _ in }
    public var enqueue: @Sendable (
        _ request: MessageDeliveryRequest
    ) async throws -> MessageDeliveryAttempt
    public var start: @Sendable () async throws -> Void = { }
}

extension MessageDeliveryOutbox: DependencyKey {
    public static let testValue = Self(
        cancelAndAwait: { _, _ in },
        enqueue: { request in
            MessageDeliveryAttempt(
                route: request.route.isCloud ? .cloud : .desktop,
                canonicalWorkspaceID: request.canonicalWorkspaceID,
                canonicalSessionID: request.canonicalSessionID,
                content: request.content,
                model: request.model,
                isFastModeEnabled: request.isFastModeEnabled,
                mode: request.mode,
                reasoningEffort: request.reasoningEffort,
                submittedDraft: request.submittedDraft,
                previousTurnID: request.previousTurnID
            )
        },
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
            enqueue: { request in
                @Dependency(\.defaultDatabase) var database
                @Dependency(\.desktopClient) var desktopClient
                return try await liveActor.enqueue(
                    request,
                    database: database,
                    desktopClient: desktopClient
                )
            },
            start: {
                @Dependency(\.cloudAPIClient) var cloudAPIClient
                @Dependency(\.continuousClock) var clock
                @Dependency(\.defaultDatabase) var database
                @Dependency(\.desktopClient) var desktopClient
                try await liveActor.start(
                    cloudAPIClient: cloudAPIClient,
                    database: database,
                    desktopClient: desktopClient,
                    sleep: { duration in
                        try await clock.sleep(for: duration)
                    }
                )
            }
        )
    }

    private static let liveActor = LiveMessageDeliveryOutbox()
}

public extension DependencyValues {
    var messageDeliveryOutbox: MessageDeliveryOutbox {
        get { self[MessageDeliveryOutbox.self] }
        set { self[MessageDeliveryOutbox.self] = newValue }
    }
}

private actor LiveMessageDeliveryOutbox {
    private struct RunningAttempt {
        let accountID: String?
        let credentialGeneration: UUID?
        let task: Task<Void, Never>
    }

    private var claimedAttemptIDs: Set<UUID> = []
    private var isStarted = false
    private var observationTask: Task<Void, Never>?
    private var runningAttempts: [UUID: RunningAttempt] = [:]

    func start(
        cloudAPIClient: CloudAPIClient,
        database: any DatabaseWriter,
        desktopClient: DesktopClient,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) async throws {
        guard !isStarted else {
            return
        }
        do {
            try await database.write { database in
                let dispatching = try MessageDeliveryAttempt
                    .where {
                        $0.state.eq(
                            MessageDeliveryAttempt.State.dispatching.rawValue
                        )
                    }
                    .fetchAll(database)
                for attempt in dispatching {
                    _ = try MessageDeliveryAttempt.compareAndSetState(
                        attemptID: attempt.attemptID,
                        from: .dispatching,
                        to: .unknown,
                        detail: "Delivery could not be determined after the app restarted.",
                        at: Date(),
                        in: database
                    )
                }
            }
        } catch {
            isStarted = false
            throw error
        }
        isStarted = true
        observationTask = Task {
            while !Task.isCancelled {
                await poll(
                    cloudAPIClient: cloudAPIClient,
                    database: database,
                    desktopClient: desktopClient
                )
                do {
                    try await sleep(.milliseconds(250))
                } catch {
                    return
                }
            }
        }
    }

    func enqueue(
        _ request: MessageDeliveryRequest,
        database: any DatabaseWriter,
        desktopClient: DesktopClient
    ) async throws -> MessageDeliveryAttempt {
        let desktopRequestLease: DesktopRequestLease?
        switch request.route {
        case .desktop:
            desktopRequestLease = try desktopClient.acquireRequestLease()
        case .cloud:
            desktopRequestLease = nil
        }
        let attempt = try await database.write { database in
            try Self.makeAttempt(
                request,
                desktopRequestLease: desktopRequestLease,
                in: database
            )
        }
        return attempt
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
        for match in matches.values {
            await match.task.value
        }
        _ = try? await database.write { database in
            let attempts = try MessageDeliveryAttempt
                .where {
                    $0.accountID.eq(accountID)
                        && $0.credentialGeneration.eq(credentialGeneration)
                }
                .fetchAll(database)
            for attempt in attempts {
                switch attempt.deliveryState {
                case .ready:
                    _ = try MessageDeliveryAttempt.compareAndSetState(
                        attemptID: attempt.attemptID,
                        from: .ready,
                        to: .rejected,
                        detail: "Cloud credentials changed before delivery began.",
                        at: Date(),
                        in: database
                    )

                case .dispatching:
                    _ = try MessageDeliveryAttempt.compareAndSetState(
                        attemptID: attempt.attemptID,
                        from: .dispatching,
                        to: .unknown,
                        detail: "Delivery could not be determined after Cloud credentials changed.",
                        at: Date(),
                        in: database
                    )

                case .accepted, .acknowledged, .rejected, .unknown:
                    break

                default:
                    break
                }
            }
        }
    }

    private func poll(
        cloudAPIClient: CloudAPIClient,
        database: any DatabaseWriter,
        desktopClient: DesktopClient
    ) async {
        let attempts: [MessageDeliveryAttempt]
        do {
            attempts = try await database.read { database in
                try MessageDeliveryAttempt
                    .where {
                        $0.state.eq(MessageDeliveryAttempt.State.ready.rawValue)
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
                    database: database,
                    desktopClient: desktopClient
                )
                await didFinish(
                    attemptID: attempt.attemptID,
                    database: database
                )
            }
            runningAttempts[attempt.attemptID] = RunningAttempt(
                accountID: attempt.accountID,
                credentialGeneration: attempt.credentialGeneration,
                task: task
            )
        }
    }

    private func didFinish(
        attemptID: UUID,
        database: any DatabaseWriter
    ) async {
        runningAttempts[attemptID] = nil
        do {
            let attempt = try await database.read { database in
                try MessageDeliveryAttempt.find(attemptID).fetchOne(database)
            }
            if attempt?.deliveryState == .ready || attempt == nil {
                claimedAttemptIDs.remove(attemptID)
            }
        } catch {
            // No transport can have started until the durable claim succeeds.
            // Let the next poll inspect and claim the row again.
            claimedAttemptIDs.remove(attemptID)
        }
    }

    private func dispatch(
        attemptID: UUID,
        cloudAPIClient: CloudAPIClient,
        database: any DatabaseWriter,
        desktopClient: DesktopClient
    ) async {
        do {
            let attempt = try await database.read { database in
                try MessageDeliveryAttempt.find(attemptID).fetchOne(database)
            }
            guard let attempt, attempt.deliveryState == .ready else {
                return
            }
            let desktopRequestLease: DesktopRequestLease?
            do {
                switch attempt.deliveryRoute {
                case .desktop:
                    desktopRequestLease = try Self.desktopRequestLease(
                        for: attempt,
                        desktopClient: desktopClient
                    )
                case .cloud:
                    try Self.validateCloudCredentials(for: attempt)
                    desktopRequestLease = nil
                default:
                    throw CloudAPIClientError.invalidResponse
                }
            } catch {
                try await database.write { database in
                    _ = try MessageDeliveryAttempt.compareAndSetState(
                        attemptID: attemptID,
                        from: .ready,
                        to: .rejected,
                        detail: error.localizedDescription,
                        at: Date(),
                        in: database
                    )
                }
                return
            }
            let didClaim = try await database.write { database in
                try MessageDeliveryAttempt.claim(
                    attemptID: attemptID,
                    at: Date(),
                    in: database
                )
            }
            guard didClaim else {
                return
            }

            let result = try await deliver(
                attempt,
                cloudAPIClient: cloudAPIClient,
                desktopClient: desktopClient,
                desktopRequestLease: desktopRequestLease
            )
            try await persist(
                result,
                for: attempt,
                database: database
            )
        } catch is CancellationError {
            await markUnknown(
                attemptID: attemptID,
                detail: "Delivery could not be determined.",
                database: database
            )
        } catch let error as CloudAPIClientError {
            if error.isDefinitiveMessageRejection {
                await transition(
                    attemptID: attemptID,
                    to: .rejected,
                    detail: error.localizedDescription,
                    database: database
                )
            } else {
                await markUnknown(
                    attemptID: attemptID,
                    detail: "Delivery could not be determined.",
                    database: database
                )
            }
        } catch {
            await markUnknown(
                attemptID: attemptID,
                detail: "Delivery could not be determined.",
                database: database
            )
        }
    }

    private func deliver(
        _ attempt: MessageDeliveryAttempt,
        cloudAPIClient: CloudAPIClient,
        desktopClient: DesktopClient,
        desktopRequestLease: DesktopRequestLease?
    ) async throws -> DeliveryDispatchResult {
        switch attempt.deliveryRoute {
        case .desktop:
            guard let desktopRequestLease else {
                throw DesktopClientError.staleRequestLease
            }
            let result = try await DesktopRequestLeaseContext.$current.withValue(
                desktopRequestLease
            ) {
                try await desktopClient.sendMessage(
                    workspaceID: attempt.canonicalWorkspaceID,
                    sessionID: attempt.canonicalSessionID,
                    message: attempt.content,
                    model: attempt.selectedModel,
                    isFastModeEnabled: attempt.isFastModeEnabled,
                    mode: attempt.messageMode,
                    reasoningEffort: attempt.selectedReasoningEffort,
                    attemptID: attempt.attemptID
                )
            }
            return DeliveryDispatchResult(result: result)

        case .cloud:
            guard let accountID = attempt.accountID,
                  let remoteSessionID = attempt.remoteSessionID else {
                throw CloudAPIClientError.invalidResponse
            }
            let response = try await cloudAPIClient.sendMessage(
                expectedAccountID: accountID,
                sessionID: remoteSessionID,
                request: CloudSendMessageRequest(
                    messageID: attempt.attemptID.uuidString.lowercased(),
                    message: attempt.content
                )
            )
            guard response.messageID.lowercased()
                    == attempt.attemptID.uuidString.lowercased(),
                  response.state == .queued || response.state == .sent else {
                throw CloudAPIClientError.invalidResponse
            }
            return DeliveryDispatchResult(
                result: .accepted(messageID: nil),
                cloudDeliveryState: response.state.rawValue
            )

        default:
            throw CloudAPIClientError.invalidResponse
        }
    }

    private func persist(
        _ dispatchResult: DeliveryDispatchResult,
        for attempt: MessageDeliveryAttempt,
        database: any DatabaseWriter
    ) async throws {
        let destination: MessageDeliveryAttempt.State
        let detail: String?
        let canonicalMessageID: Message.ID?
        switch dispatchResult.result {
        case let .accepted(messageID):
            destination = .accepted
            detail = nil
            canonicalMessageID = messageID

        case let .rejected(reason):
            destination = .rejected
            detail = reason
            canonicalMessageID = nil

        case let .unknown(reason):
            destination = .unknown
            detail = reason
            canonicalMessageID = nil
        }
        try await database.write { database in
            _ = try MessageDeliveryAttempt.compareAndSetState(
                attemptID: attempt.attemptID,
                from: .dispatching,
                to: destination,
                detail: detail,
                cloudDeliveryState: dispatchResult.cloudDeliveryState,
                canonicalMessageID: canonicalMessageID,
                at: Date(),
                in: database
            )
        }
    }

    private func markUnknown(
        attemptID: UUID,
        detail: String,
        database: any DatabaseWriter
    ) async {
        await transition(
            attemptID: attemptID,
            to: .unknown,
            detail: detail,
            database: database
        )
    }

    private func transition(
        attemptID: UUID,
        to destination: MessageDeliveryAttempt.State,
        detail: String,
        database: any DatabaseWriter
    ) async {
        _ = try? await database.write { database in
            try MessageDeliveryAttempt.compareAndSetState(
                attemptID: attemptID,
                from: .dispatching,
                to: destination,
                detail: detail,
                at: Date(),
                in: database
            )
        }
    }

    private nonisolated static func makeAttempt(
        _ request: MessageDeliveryRequest,
        desktopRequestLease: DesktopRequestLease?,
        in database: Database
    ) throws -> MessageDeliveryAttempt {
        switch request.route {
        case .desktop:
            guard let desktopRequestLease else {
                throw DesktopClientError.invalidServerAddress
            }
            let attempt = MessageDeliveryAttempt(
                route: .desktop,
                desktopEndpoint: desktopRequestLease.baseURL.absoluteString,
                canonicalWorkspaceID: request.canonicalWorkspaceID,
                canonicalSessionID: request.canonicalSessionID,
                content: request.content,
                model: request.model,
                isFastModeEnabled: request.isFastModeEnabled,
                mode: request.mode,
                reasoningEffort: request.reasoningEffort,
                submittedDraft: request.submittedDraft,
                previousTurnID: request.previousTurnID
            )
            try MessageDeliveryAttempt.insert { attempt }.execute(database)
            return attempt

        case let .cloud(accountID, remoteWorkspaceID):
            @Shared(.cloudConfiguration) var configuration
            guard let configuration,
                  configuration.accountID == accountID,
                  let metadata = try CloudSessionMetadata
                    .find(request.canonicalSessionID)
                    .fetchOne(database),
                  metadata.accountID == accountID,
                  metadata.workspaceID == request.canonicalWorkspaceID,
                  let workspace = try CloudWorkspaceMetadata
                    .find(request.canonicalWorkspaceID)
                    .fetchOne(database),
                  workspace.accountID == accountID,
                  workspace.remoteWorkspaceID == remoteWorkspaceID else {
                throw MessageDeliveryOutboxError.ownershipMismatch
            }
            let attempt = MessageDeliveryAttempt(
                route: .cloud,
                accountID: accountID,
                credentialGeneration: configuration.credentialGeneration,
                canonicalWorkspaceID: request.canonicalWorkspaceID,
                remoteWorkspaceID: remoteWorkspaceID,
                canonicalSessionID: request.canonicalSessionID,
                remoteSessionID: metadata.cloudSessionID,
                content: request.content,
                model: request.model,
                isFastModeEnabled: request.isFastModeEnabled,
                mode: request.mode,
                reasoningEffort: request.reasoningEffort,
                submittedDraft: request.submittedDraft,
                previousTurnID: request.previousTurnID
            )
            try MessageDeliveryAttempt.insert { attempt }.execute(database)
            return attempt
        }
    }

    private nonisolated static func desktopRequestLease(
        for attempt: MessageDeliveryAttempt,
        desktopClient: DesktopClient
    ) throws -> DesktopRequestLease {
        guard let expectedEndpoint = attempt.desktopEndpoint else {
            throw MessageDeliveryOutboxError.desktopEndpointChanged
        }
        let requestLease = try desktopClient.acquireRequestLease()
        guard requestLease.baseURL.absoluteString == expectedEndpoint else {
            throw MessageDeliveryOutboxError.desktopEndpointChanged
        }
        return requestLease
    }

    private nonisolated static func validateCloudCredentials(
        for attempt: MessageDeliveryAttempt
    ) throws {
        @Shared(.cloudConfiguration) var configuration
        guard configuration?.accountID == attempt.accountID,
              configuration?.credentialGeneration
                == attempt.credentialGeneration else {
            throw MessageDeliveryOutboxError.credentialsChanged
        }
    }
}

private struct DeliveryDispatchResult {
    let result: MessageDeliveryResult
    let cloudDeliveryState: String?

    init(
        result: MessageDeliveryResult,
        cloudDeliveryState: String? = nil
    ) {
        self.result = result
        self.cloudDeliveryState = cloudDeliveryState
    }
}

private enum MessageDeliveryOutboxError: LocalizedError {
    case credentialsChanged
    case desktopEndpointChanged
    case ownershipMismatch

    var errorDescription: String? {
        switch self {
        case .credentialsChanged:
            "The active Conductor Cloud credential changed."
        case .desktopEndpointChanged:
            "The desktop configuration changed before delivery began."
        case .ownershipMismatch:
            "This Cloud chat is read-only for the current account."
        }
    }
}

private extension WorkspaceMutationRoute {
    var isCloud: Bool {
        if case .cloud = self {
            true
        } else {
            false
        }
    }
}

private extension CloudAPIClientError {
    var isDefinitiveMessageRejection: Bool {
        guard case let .requestFailed(statusCode, error) = self else {
            return self == .unexpectedAccount
        }
        if error?.retryable == true || (500..<600).contains(statusCode) {
            return false
        }
        return (400..<500).contains(statusCode)
    }
}
