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
            operation: .cancelSession,
            resourceKind: .session,
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
            operation: .cancelSession,
            resourceKind: .session,
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

    @Test("Workspace creation baselines and prompts round trip")
    func workspaceCreationRoundTrip() throws {
        let payload = CloudWorkspaceCreationPayload(
            request: CloudCreateWorkspaceRequest(
                projectID: "project",
                sessionName: "Conductor Mobile recovery-token",
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
            baselineRemoteWorkspaceIDs: ["a", "b"]
        )
        let attempt = try CloudPendingMutation(
            accountID: "account",
            credentialGeneration: UUID(3),
            operation: .createWorkspace,
            resourceKind: .workspace,
            request: payload
        )
        #expect(
            try attempt.request(as: CloudWorkspaceCreationPayload.self)
                == payload
        )
    }
}
