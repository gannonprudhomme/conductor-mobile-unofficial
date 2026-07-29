//
//  MessageDeliveryAttemptTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/29/26.
//

import Foundation
import SharedConductorData
import SQLiteData
@testable import ConductorMobileData
import Testing

struct MessageDeliveryAttemptTests {
    @Test("An attempt can be claimed only once")
    func claimIsCompareAndSet() throws {
        let database = try appDatabase()
        let attempt = makeAttempt()

        try database.write { database in
            try MessageDeliveryAttempt.insert { attempt }.execute(database)

            #expect(
                try MessageDeliveryAttempt.claim(
                    attemptID: attempt.attemptID,
                    at: Date(timeIntervalSince1970: 2),
                    in: database
                )
            )
            #expect(
                try MessageDeliveryAttempt.claim(
                    attemptID: attempt.attemptID,
                    at: Date(timeIntervalSince1970: 3),
                    in: database
                ) == false
            )

            let persisted = try #require(
                try MessageDeliveryAttempt.find(attempt.attemptID)
                    .fetchOne(database)
            )
            #expect(persisted.deliveryState == .dispatching)
            #expect(
                persisted.dispatchStartedAt
                    == Date(timeIntervalSince1970: 2)
            )
        }
    }

    @Test("Delivery transitions are monotonic")
    func monotonicTransitions() throws {
        let database = try appDatabase()
        let attempt = makeAttempt()

        try database.write { database in
            try MessageDeliveryAttempt.insert { attempt }.execute(database)
            #expect(
                try MessageDeliveryAttempt.claim(
                    attemptID: attempt.attemptID,
                    at: Date(timeIntervalSince1970: 2),
                    in: database
                )
            )
            #expect(
                try MessageDeliveryAttempt.compareAndSetState(
                    attemptID: attempt.attemptID,
                    from: .dispatching,
                    to: .accepted,
                    canonicalMessageID: "canonical",
                    at: Date(timeIntervalSince1970: 3),
                    in: database
                )
            )
            #expect(
                try MessageDeliveryAttempt.compareAndSetState(
                    attemptID: attempt.attemptID,
                    from: .accepted,
                    to: .rejected,
                    at: Date(timeIntervalSince1970: 4),
                    in: database
                ) == false
            )
            #expect(
                try MessageDeliveryAttempt.acknowledge(
                    attemptID: attempt.attemptID,
                    canonicalMessageID: "canonical",
                    canonicalTurnID: "turn",
                    at: Date(timeIntervalSince1970: 5),
                    in: database
                )
            )

            let persisted = try #require(
                try MessageDeliveryAttempt.find(attempt.attemptID)
                    .fetchOne(database)
            )
            #expect(persisted.deliveryState == .acknowledged)
            #expect(persisted.canonicalMessageID == "canonical")
            #expect(persisted.canonicalTurnID == "turn")
        }
    }

    @Test("Desktop acknowledgement requires a protocol identifier")
    func desktopAcknowledgementUsesProtocolIdentifier() throws {
        let database = try appDatabase()
        let attempt = makeAttempt(state: .unknown)
        let unrelated = Message(
            id: "unrelated",
            sessionID: attempt.canonicalSessionID,
            role: .user,
            content: attempt.content,
            createdAt: Date(timeIntervalSince1970: 2),
            turnID: "different-turn"
        )
        let matching = Message(
            id: "canonical",
            sessionID: attempt.canonicalSessionID,
            role: .user,
            content: attempt.content,
            createdAt: Date(timeIntervalSince1970: 3),
            turnID: attempt.attemptID.uuidString
        )

        try database.write { database in
            try MessageDeliveryAttempt.insert { attempt }.execute(database)
            try MessageDeliveryAttempt.acknowledgeDesktopMessages(
                [unrelated],
                sessionID: attempt.canonicalSessionID,
                in: database
            )
            #expect(
                try MessageDeliveryAttempt.find(attempt.attemptID)
                    .fetchOne(database)?
                    .deliveryState == .unknown
            )

            try MessageDeliveryAttempt.acknowledgeDesktopMessages(
                [matching],
                sessionID: attempt.canonicalSessionID,
                in: database
            )
            let persisted = try #require(
                try MessageDeliveryAttempt.find(attempt.attemptID)
                    .fetchOne(database)
            )
            #expect(persisted.deliveryState == .acknowledged)
            #expect(persisted.canonicalMessageID == matching.id)
            #expect(persisted.canonicalTurnID == matching.turnID)
        }
    }
}

private func makeAttempt(
    state: MessageDeliveryAttempt.State = .ready
) -> MessageDeliveryAttempt {
    MessageDeliveryAttempt(
        attemptID: UUID(0),
        route: .desktop,
        canonicalWorkspaceID: "workspace",
        canonicalSessionID: "session",
        content: "Implement it",
        model: Session.Model(rawValue: "sonnet-4-6"),
        isFastModeEnabled: false,
        mode: .sent,
        reasoningEffort: .high,
        submittedDraft: "Implement it",
        state: state,
        createdAt: Date(timeIntervalSince1970: 1)
    )
}
