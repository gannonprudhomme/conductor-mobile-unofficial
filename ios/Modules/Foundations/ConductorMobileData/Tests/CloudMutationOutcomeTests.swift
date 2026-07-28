//
//  CloudMutationOutcomeTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/28/26.
//

import Foundation
@testable import ConductorMobileData
import Testing

struct CloudMutationOutcomeTests {
    @Test("Rejection presentation data survives persistence")
    func rejectionRoundTrip() throws {
        let payload = CloudMutationRejectionPayload(
            title: "Send failed",
            message: "Try again",
            operation: "send-message",
            canonicalWorkspaceID: "workspace",
            canonicalSessionID: "session"
        )
        let outcome = try CloudMutationOutcome(
            attemptID: UUID(0),
            accountID: "account",
            credentialGeneration: UUID(1),
            owningFeature: .chat(sessionID: "session"),
            kind: .rejectedMutation,
            payload: payload
        )

        #expect(
            try outcome.decodedPayload(
                as: CloudMutationRejectionPayload.self
            ) == payload
        )
        #expect(outcome.consumedAt == nil)
    }
}
