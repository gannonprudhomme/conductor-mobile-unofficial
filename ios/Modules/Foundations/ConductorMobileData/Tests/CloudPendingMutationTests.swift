//
//  CloudPendingMutationTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/28/26.
//

import ConductorCloud
import Foundation
import SharedConductorData
@testable import ConductorMobileData
import Testing

struct CloudPendingMutationTests {
    @Test("Mutation transitions are monotonic and acknowledged is terminal")
    func monotonicTransitions() throws {
        let database = try appDatabase()
        let attempt = try CloudPendingMutation(
            attemptID: UUID(0),
            accountID: "account",
            credentialGeneration: UUID(1),
            operation: .sendMessage,
            resourceKind: .message,
            request: CloudSendMessageRequest(
                messageID: "message",
                message: "Hello"
            ),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        try database.write { database in
            try CloudPendingMutation.insert { attempt }.execute(database)
            #expect(
                try CloudPendingMutation.compareAndSetState(
                    attemptID: attempt.attemptID,
                    from: .submitting,
                    to: .acknowledged,
                    at: Date(timeIntervalSince1970: 2),
                    in: database
                )
            )
            #expect(
                !CloudPendingMutation.State.acknowledged.canTransition(
                    to: .accepted
                )
            )
            #expect(
                try CloudPendingMutation.compareAndSetState(
                    attemptID: attempt.attemptID,
                    from: .acknowledged,
                    to: .accepted,
                    at: Date(timeIntervalSince1970: 3),
                    in: database
                ) == false
            )
        }
    }

    @Test("Attempt payloads and credential generations round trip")
    func payloadRoundTrip() throws {
        let generation = UUID(2)
        let attempt = try CloudPendingMutation(
            accountID: "account",
            credentialGeneration: generation,
            operation: .sendMessage,
            resourceKind: .message,
            request: CloudSendMessageRequest(
                messageID: "stable",
                message: "Hello"
            ),
            stableRemoteMessageID: "stable"
        )

        #expect(attempt.credentialGeneration == generation)
        #expect(
            try attempt.request(as: CloudSendMessageRequest.self)
                == CloudSendMessageRequest(
                    messageID: "stable",
                    message: "Hello"
                )
        )
    }

    @Test("Workspace creation baselines and prompt handoffs round trip")
    func workspaceCreationRoundTrip() throws {
        let capturedAt = Date(timeIntervalSince1970: 42)
        let payload = CloudWorkspaceCreationPayload(
            request: CloudCreateWorkspaceRequest(
                projectID: "project",
                agent: "claude",
                model: "sonnet-4-6",
                effort: "high"
            ),
            canonicalRepositoryID: "repository",
            projectID: "project",
            repositoryURL: nil,
            selectedModel: Session.Model(rawValue: "sonnet-4-6"),
            selectedReasoningEffort: .high,
            prompt: "Implement it",
            baselineRemoteWorkspaceIDs: ["a", "b"],
            baselineCapturedAt: capturedAt
        )
        let attempt = try CloudPendingMutation(
            accountID: "account",
            credentialGeneration: UUID(3),
            operation: .createWorkspace,
            resourceKind: .workspace,
            request: payload
        )
        let handoff = InitialPromptHandoff(
            creationAttemptID: attempt.attemptID,
            accountID: attempt.accountID,
            credentialGeneration: attempt.credentialGeneration,
            canonicalWorkspaceID: "workspace",
            remoteWorkspaceID: "remote-workspace",
            canonicalSessionID: "session",
            remoteSessionID: "remote-session",
            originalPrompt: payload.prompt,
            installedDraftText: "Existing\n\nImplement it",
            state: .linked,
            createdAt: capturedAt
        )

        #expect(
            try attempt.request(as: CloudWorkspaceCreationPayload.self)
                == payload
        )
        #expect(handoff.handoffState == .linked)
        #expect(handoff.installedDraftText == "Existing\n\nImplement it")
    }
}
