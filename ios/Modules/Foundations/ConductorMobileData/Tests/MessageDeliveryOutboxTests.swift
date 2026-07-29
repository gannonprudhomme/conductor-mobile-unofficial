//
//  MessageDeliveryOutboxTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/29/26.
//

import ComposableArchitecture
import ConductorCloud
import Foundation
import Sharing
import SharedConductorData
import SQLiteData
@testable import ConductorMobileData
import Testing

struct MessageDeliveryOutboxTests {
    @Test("Enqueue durably stores the complete desktop request")
    func enqueueDesktopRequest() async throws {
        let desktopRequestLease = DesktopRequestLease(
            baseURL: try #require(URL(string: "http://desktop:3768")),
            endpointEpoch: 1
        )
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
            $0.desktopClient.acquireRequestLease = { desktopRequestLease }
            $0.messageDeliveryOutbox = .liveValue
        } operation: {
            @Dependency(\.defaultDatabase) var database
            @Dependency(\.messageDeliveryOutbox) var outbox
            let session = Session.preview(
                id: "session",
                workspaceID: "workspace",
                model: Session.Model(rawValue: "sonnet-4-6"),
                claudeEffortLevel: .high
            )

            let attempt = try await outbox.enqueue(
                MessageDeliveryRequest(
                    route: .desktop,
                    canonicalWorkspaceID: session.workspaceID,
                    canonicalSessionID: session.id,
                    content: "Implement it",
                    model: session.model,
                    isFastModeEnabled: true,
                    mode: .queued,
                    reasoningEffort: session.reasoningEffort,
                    submittedDraft: "  Implement it  ",
                    previousTurnID: "previous-turn"
                )
            )
            let persisted = try await database.read { database in
                try #require(
                    try MessageDeliveryAttempt.find(attempt.attemptID)
                        .fetchOne(database)
                )
            }

            #expect(persisted.deliveryRoute == .desktop)
            #expect(persisted.deliveryState == .ready)
            #expect(
                persisted.desktopEndpoint
                    == desktopRequestLease.baseURL.absoluteString
            )
            #expect(persisted.canonicalWorkspaceID == session.workspaceID)
            #expect(persisted.canonicalSessionID == session.id)
            #expect(persisted.content == "Implement it")
            #expect(persisted.selectedModel == session.model)
            #expect(persisted.isFastModeEnabled)
            #expect(persisted.messageMode == .queued)
            #expect(
                persisted.selectedReasoningEffort
                    == session.reasoningEffort
            )
            #expect(persisted.submittedDraft == "  Implement it  ")
            #expect(persisted.previousTurnID == "previous-turn")
            #expect(persisted.dispatchStartedAt == nil)
        }
    }

    @Test("Credential cancellation resolves active Cloud attempts")
    func cancelCloudAttempts() async throws {
        let accountID = "account"
        let generation = UUID(20)
        let ready = cloudAttempt(
            attemptID: UUID(21),
            accountID: accountID,
            generation: generation,
            state: .ready
        )
        let dispatching = cloudAttempt(
            attemptID: UUID(22),
            accountID: accountID,
            generation: generation,
            state: .dispatching
        )

        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
            $0.messageDeliveryOutbox = .liveValue
        } operation: {
            @Dependency(\.defaultDatabase) var database
            @Dependency(\.messageDeliveryOutbox) var outbox
            try await database.write { database in
                try MessageDeliveryAttempt
                    .insert { [ready, dispatching] }
                    .execute(database)
            }

            await outbox.cancelAndAwait(accountID, generation)

            let attempts = try await database.read { database in
                try MessageDeliveryAttempt.all
                    .order(by: \.createdAt)
                    .fetchAll(database)
            }
            #expect(attempts.map(\.deliveryState) == [.rejected, .unknown])
        }
    }

    @Test("Startup dispatches ready rows once and never reposts started rows")
    func startupRecoveryAndDispatch() async throws {
        let deliveredAttemptIDs = LockIsolated<[UUID]>([])
        let cloudRequests = LockIsolated<[(messageID: String, message: String)]>(
            []
        )
        let accountID = "account"
        let generation = UUID(31)
        let desktopRequestLease = DesktopRequestLease(
            baseURL: try #require(URL(string: "http://desktop:3768")),
            endpointEpoch: 1
        )
        let started = MessageDeliveryAttempt(
            attemptID: UUID(30),
            route: .desktop,
            canonicalWorkspaceID: "workspace",
            canonicalSessionID: "session",
            content: "Already started",
            model: .gpt_5_6_sol,
            isFastModeEnabled: false,
            mode: .sent,
            reasoningEffort: .high,
            submittedDraft: "Already started",
            state: .dispatching,
            dispatchStartedAt: Date(timeIntervalSince1970: 1),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let staleEndpoint = MessageDeliveryAttempt(
            attemptID: UUID(32),
            route: .desktop,
            desktopEndpoint: "http://previous-desktop:3768",
            canonicalWorkspaceID: "workspace",
            canonicalSessionID: "session",
            content: "Stale endpoint",
            model: .gpt_5_6_sol,
            isFastModeEnabled: false,
            mode: .sent,
            reasoningEffort: .high,
            submittedDraft: "Stale endpoint",
            createdAt: Date(timeIntervalSince1970: 2)
        )

        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
            $0.continuousClock = ContinuousClock()
            $0.messageDeliveryOutbox = .liveValue
            $0.desktopClient.acquireRequestLease = { desktopRequestLease }
            $0.desktopClient.sendMessage = {
                _,
                _,
                message,
                _,
                _,
                _,
                _,
                attemptID in
                deliveredAttemptIDs.withValue { $0.append(attemptID) }
                return switch message {
                case "Rejected":
                    .rejected(reason: "Rejected.")
                case "Unknown":
                    .unknown(reason: "Unknown.")
                default:
                    .accepted(messageID: "canonical")
                }
            }
            $0.cloudAPIClient.sendMessage = {
                expectedAccountID,
                sessionID,
                request in
                #expect(expectedAccountID == accountID)
                #expect(sessionID == "remote-session")
                cloudRequests.withValue {
                    $0.append((request.messageID, request.message))
                }
                let responseMessageID = request.message == "Malformed"
                    ? UUID().uuidString
                    : request.messageID
                return try JSONDecoder().decode(
                    CloudSendMessageResponse.self,
                    from: Data(
                        """
                        {
                          "messageId": "\(responseMessageID)",
                          "state": "queued"
                        }
                        """.utf8
                    )
                )
            }
        } operation: {
            @Dependency(\.defaultDatabase) var database
            @Dependency(\.messageDeliveryOutbox) var outbox
            @Shared(.cloudConfiguration) var configuration
            $configuration.withLock {
                $0 = CloudConfiguration(
                    accountID: accountID,
                    credentialGeneration: generation
                )
            }
            let workspace = Workspace.preview(id: "cloud-workspace")
            let session = Session.preview(
                id: "cloud-session",
                workspaceID: workspace.id
            )
            try await database.write { database in
                try MessageDeliveryAttempt.insert { [started, staleEndpoint] }
                    .execute(database)
                try Workspace.insert { workspace }.execute(database)
                try Session.insert { session }.execute(database)
                try CloudWorkspaceMetadata.insert {
                    CloudWorkspaceMetadata(
                        workspaceID: workspace.id,
                        accountID: accountID,
                        remoteWorkspaceID: "remote-workspace",
                        lastSeenGeneration: "generation"
                    )
                }
                .execute(database)
                try CloudSessionMetadata.insert {
                    CloudSessionMetadata(
                        canonicalSessionID: session.id,
                        cloudSessionID: "remote-session",
                        workspaceID: workspace.id,
                        accountID: accountID,
                        listOrder: 0,
                        refreshGeneration: "generation"
                    )
                }
                .execute(database)
            }
            let ready = try await outbox.enqueue(
                MessageDeliveryRequest(
                    route: .desktop,
                    canonicalWorkspaceID: "workspace",
                    canonicalSessionID: "session",
                    content: "Ready",
                    model: .gpt_5_6_sol,
                    isFastModeEnabled: false,
                    mode: .sent,
                    reasoningEffort: .high,
                    submittedDraft: "Ready",
                    previousTurnID: nil
                )
            )
            let rejected = try await outbox.enqueue(
                MessageDeliveryRequest(
                    route: .desktop,
                    canonicalWorkspaceID: "workspace",
                    canonicalSessionID: "session",
                    content: "Rejected",
                    model: .gpt_5_6_sol,
                    isFastModeEnabled: false,
                    mode: .sent,
                    reasoningEffort: .high,
                    submittedDraft: "Rejected",
                    previousTurnID: nil
                )
            )
            let unknown = try await outbox.enqueue(
                MessageDeliveryRequest(
                    route: .desktop,
                    canonicalWorkspaceID: "workspace",
                    canonicalSessionID: "session",
                    content: "Unknown",
                    model: .gpt_5_6_sol,
                    isFastModeEnabled: false,
                    mode: .sent,
                    reasoningEffort: .high,
                    submittedDraft: "Unknown",
                    previousTurnID: nil
                )
            )
            let cloud = try await outbox.enqueue(
                MessageDeliveryRequest(
                    route: .cloud(
                        accountID: accountID,
                        remoteWorkspaceID: "remote-workspace"
                    ),
                    canonicalWorkspaceID: workspace.id,
                    canonicalSessionID: session.id,
                    content: "Cloud ready",
                    model: session.model,
                    isFastModeEnabled: false,
                    mode: .sent,
                    reasoningEffort: session.reasoningEffort,
                    submittedDraft: "Cloud ready",
                    previousTurnID: nil
                )
            )
            let malformed = try await outbox.enqueue(
                MessageDeliveryRequest(
                    route: .cloud(
                        accountID: accountID,
                        remoteWorkspaceID: "remote-workspace"
                    ),
                    canonicalWorkspaceID: workspace.id,
                    canonicalSessionID: session.id,
                    content: "Malformed",
                    model: session.model,
                    isFastModeEnabled: false,
                    mode: .sent,
                    reasoningEffort: session.reasoningEffort,
                    submittedDraft: "Malformed",
                    previousTurnID: nil
                )
            )

            try await outbox.start()
            let clock = ContinuousClock()
            for _ in 0..<100 {
                let state = try await database.read { database in
                    try MessageDeliveryAttempt.find(ready.attemptID)
                        .fetchOne(database)?
                        .deliveryState
                }
                let cloudState = try await database.read { database in
                    try MessageDeliveryAttempt.find(cloud.attemptID)
                        .fetchOne(database)?
                        .deliveryState
                }
                let otherStates = try await database.read { database in
                    try [rejected, unknown, malformed, staleEndpoint].map {
                        try MessageDeliveryAttempt.find($0.attemptID)
                            .fetchOne(database)?
                            .deliveryState
                    }
                }
                if state == .accepted,
                   cloudState == .accepted,
                   otherStates == [.rejected, .unknown, .unknown, .rejected] {
                    break
                }
                try await clock.sleep(for: .milliseconds(20))
            }
            try await clock.sleep(for: .milliseconds(300))

            let attempts = try await database.read { database in
                try MessageDeliveryAttempt.all.fetchAll(database)
            }
            let states = Dictionary(
                uniqueKeysWithValues: attempts.map {
                    ($0.attemptID, $0.deliveryState)
                }
            )
            #expect(states[started.attemptID] == .unknown)
            #expect(states[ready.attemptID] == .accepted)
            #expect(states[rejected.attemptID] == .rejected)
            #expect(states[unknown.attemptID] == .unknown)
            #expect(states[cloud.attemptID] == .accepted)
            #expect(
                attempts.first { $0.attemptID == cloud.attemptID }?
                    .cloudDeliveryState
                    == CloudSendMessageResponse.State.queued.rawValue
            )
            #expect(states[malformed.attemptID] == .unknown)
            #expect(states[staleEndpoint.attemptID] == .rejected)
            #expect(
                Set(deliveredAttemptIDs.value)
                    == [ready.attemptID, rejected.attemptID, unknown.attemptID]
            )
            #expect(deliveredAttemptIDs.value.count == 3)
            #expect(
                Set(cloudRequests.value.map(\.messageID))
                    == [
                        cloud.attemptID.uuidString.lowercased(),
                        malformed.attemptID.uuidString.lowercased(),
                    ]
            )
            #expect(
                Set(cloudRequests.value.map(\.message))
                    == ["Cloud ready", "Malformed"]
            )
        }
    }
}

private func cloudAttempt(
    attemptID: UUID,
    accountID: String,
    generation: UUID,
    state: MessageDeliveryAttempt.State
) -> MessageDeliveryAttempt {
    MessageDeliveryAttempt(
        attemptID: attemptID,
        route: .cloud,
        accountID: accountID,
        credentialGeneration: generation,
        canonicalWorkspaceID: "workspace",
        remoteWorkspaceID: "remote-workspace",
        canonicalSessionID: "session",
        remoteSessionID: "remote-session",
        content: "Implement it",
        model: Session.Model(rawValue: "sonnet-4-6"),
        isFastModeEnabled: false,
        mode: .sent,
        reasoningEffort: .high,
        submittedDraft: "Implement it",
        state: state,
        dispatchStartedAt: state == .dispatching ? Date() : nil,
        createdAt: Date(
            timeIntervalSince1970: attemptID == UUID(21) ? 1 : 2
        )
    )
}
