//
//  CloudChatPersistenceTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/28/26.
//

import ConductorCloud
import Foundation
import SharedConductorData
@testable import ConductorMobileData
import Testing

struct CloudChatPersistenceTests {
    @Test("An idle snapshot retires a cancel and releases a removed session")
    func cancelReconciliation() throws {
        let database = try appDatabase()
        let accountID = "account"
        let remoteSessionID = "session"
        let canonicalSessionID = CloudCanonicalID.session(
            accountID: accountID,
            remoteSessionID: remoteSessionID
        )
        let attempt = try CloudPendingMutation(
            attemptID: UUID(48),
            accountID: accountID,
            credentialGeneration: UUID(49),
            operation: .cancelSession,
            resourceKind: .session,
            request: CloudSendMessageRequest(
                messageID: "unused",
                message: "unused"
            ),
            canonicalWorkspaceID: "workspace",
            remoteWorkspaceID: "workspace",
            canonicalSessionID: canonicalSessionID,
            remoteSessionID: remoteSessionID,
            state: .accepted
        )

        try database.write { database in
            _ = try CloudChatPersistence.persist(
                snapshot(
                    accountID: accountID,
                    sessionIDs: [remoteSessionID]
                ),
                in: database
            )
            try CloudPendingMutation.insert { attempt }.execute(database)
            _ = try CloudChatPersistence.persist(
                snapshot(
                    accountID: accountID,
                    sessionIDs: [remoteSessionID]
                ),
                in: database
            )
            _ = try CloudChatPersistence.persist(
                snapshot(accountID: accountID, sessionIDs: []),
                in: database
            )
        }

        let persisted = try database.read { database in
            (
                attempt: try CloudPendingMutation
                    .find(attempt.attemptID)
                    .fetchOne(database),
                session: try Session
                    .find(canonicalSessionID)
                    .fetchOne(database)
            )
        }
        #expect(persisted.attempt == nil)
        #expect(persisted.session == nil)
    }

    @Test("UUID session IDs reconcile across API casing")
    func uuidSessionIDCaseReconciliation() throws {
        let database = try appDatabase()
        let uppercaseSessionID = "F427FF06-F941-4C3E-B214-104592EC27E8"
        let lowercaseSessionID = uppercaseSessionID.lowercased()

        try database.write { db in
            _ = try CloudChatPersistence.persist(
                snapshot(
                    accountID: "account-a",
                    sessionIDs: [uppercaseSessionID]
                ),
                in: db
            )
            _ = try CloudChatPersistence.persist(
                snapshot(
                    accountID: "account-a",
                    sessionIDs: [lowercaseSessionID]
                ),
                in: db
            )
        }

        let sessions = try database.read { db in
            try CloudSessionMetadata
                .sessions(workspaceID: "workspace", isHidden: false)
                .fetchAll(db)
        }
        #expect(sessions.count == 1)
        #expect(
            sessions[0].id
                == CloudCanonicalID.session(
                    accountID: "account-a",
                    remoteSessionID: lowercaseSessionID
                )
        )
        #expect(
            CloudCanonicalID.session(
                accountID: "account-a",
                remoteSessionID: uppercaseSessionID
            ) == CloudCanonicalID.session(
                accountID: "account-a",
                remoteSessionID: lowercaseSessionID
            )
        )
        #expect(
            CloudCanonicalID.session(
                accountID: "account-a",
                remoteSessionID: "CaseSensitive"
            ) != CloudCanonicalID.session(
                accountID: "account-a",
                remoteSessionID: "casesensitive"
            )
        )
    }

    @Test("Cloud sessions remain isolated and query in API order")
    func sessionIsolationAndOrder() throws {
        let database = try appDatabase()
        let desktopSession = Session.preview(
            id: "remote-session",
            workspaceID: "workspace"
        )
        try database.write { db in
            try Session.insert { desktopSession }.execute(db)
            _ = try CloudChatPersistence.persist(
                snapshot(
                    accountID: "account-a",
                    sessionIDs: ["second", "remote-session", "first"]
                ),
                in: db
            )
        }

        let cloudSessions = try database.read { db in
            try CloudSessionMetadata
                .sessions(workspaceID: "workspace", isHidden: false)
                .fetchAll(db)
        }
        let storedDesktopSession = try database.read { db in
            try Session.find(desktopSession.id).fetchOne(db)
        }

        #expect(
            cloudSessions.map(\.id)
                == ["second", "remote-session", "first"].map {
                    CloudCanonicalID.session(
                        accountID: "account-a",
                        remoteSessionID: $0
                    )
                }
        )
        #expect(storedDesktopSession == desktopSession)
        #expect(
            CloudCanonicalID.session(
                accountID: "account-a",
                remoteSessionID: "same"
            )
                != CloudCanonicalID.session(
                    accountID: "account-b",
                    remoteSessionID: "same"
                )
        )
    }

    @Test("Desktop visibility survives later Cloud snapshots")
    func desktopVisibilitySurvivesCloudRefresh() throws {
        let database = try appDatabase()
        let canonicalSessionID = CloudCanonicalID.session(
            accountID: "account",
            remoteSessionID: "archived"
        )

        try database.write { database in
            _ = try CloudChatPersistence.persist(
                snapshot(accountID: "account", sessionIDs: ["archived"]),
                in: database
            )
            _ = try CloudChatPersistence.reconcileSessionVisibility(
                from: [
                    Session.preview(
                        id: "archived",
                        workspaceID: "workspace",
                        isHidden: true
                    ),
                ],
                canonicalWorkspaceID: "workspace",
                remoteWorkspaceID: "workspace",
                in: database
            )
            _ = try CloudChatPersistence.persist(
                snapshot(accountID: "account", sessionIDs: ["archived"]),
                in: database
            )
        }

        let session = try database.read { database in
            try Session.find(canonicalSessionID).fetchOne(database)
        }
        #expect(session?.isHidden == true)
    }

    @Test("Partial Cloud snapshots preserve known session configuration")
    func partialSnapshotPreservesSessionConfiguration() throws {
        let database = try appDatabase()
        let canonicalSessionID = CloudCanonicalID.session(
            accountID: "account",
            remoteSessionID: "session"
        )

        try database.write { database in
            _ = try CloudChatPersistence.persist(
                snapshot(
                    accountID: "account",
                    sessionIDs: ["session"],
                    effort: "high",
                    fastMode: true
                ),
                in: database
            )
            _ = try CloudChatPersistence.persist(
                snapshot(
                    accountID: "account",
                    sessionIDs: ["session"],
                    effort: nil,
                    fastMode: nil
                ),
                in: database
            )
        }

        let session = try database.read { database in
            try Session.find(canonicalSessionID).fetchOne(database)
        }
        #expect(session?.reasoningEffort == .high)
        #expect(session?.isFastModeEnabled == true)
    }

    @Test("Account replacement removes only the old Cloud-owned rows")
    func accountReplacement() throws {
        let database = try appDatabase()
        let desktopSession = Session.preview(
            id: "desktop-session",
            workspaceID: "workspace"
        )
        try database.write { db in
            try Session.insert { desktopSession }.execute(db)
            _ = try CloudChatPersistence.persist(
                snapshot(accountID: "account-a", sessionIDs: ["same"]),
                in: db
            )
            _ = try CloudChatPersistence.persist(
                snapshot(accountID: "account-b", sessionIDs: ["same"]),
                in: db
            )
        }

        let sessionIDs = try database.read { db in
            try Session.all.fetchAll(db).map(\.id)
        }
        #expect(sessionIDs.contains(desktopSession.id))
        #expect(
            !sessionIDs.contains(
                CloudCanonicalID.session(
                    accountID: "account-a",
                    remoteSessionID: "same"
                )
            )
        )
        #expect(
            sessionIDs.contains(
                CloudCanonicalID.session(
                    accountID: "account-b",
                    remoteSessionID: "same"
                )
            )
        )
    }

    @Test("Canonical workspace snapshots remove sessions absent from the API")
    func canonicalWorkspaceRemovesStaleSessions() throws {
        let database = try appDatabase()
        let accountID = "account"
        let remoteWorkspaceID = "workspace"
        let canonicalWorkspaceID = CloudCanonicalID.workspace(
            accountID: accountID,
            remoteWorkspaceID: remoteWorkspaceID
        )
        let workspace = Workspace.preview(id: canonicalWorkspaceID)

        try database.write { db in
            try Workspace.insert { workspace }.execute(db)
            try CloudWorkspaceMetadata
                .insert {
                    CloudWorkspaceMetadata(
                        workspaceID: canonicalWorkspaceID,
                        accountID: accountID,
                        remoteWorkspaceID: remoteWorkspaceID,
                        lastSeenGeneration: "generation"
                    )
                }
                .execute(db)
            _ = try CloudChatPersistence.persist(
                snapshot(
                    accountID: accountID,
                    sessionIDs: ["kept", "stale"]
                ),
                in: db
            )
            _ = try CloudChatPersistence.persist(
                snapshot(
                    accountID: accountID,
                    sessionIDs: ["kept"]
                ),
                in: db
            )
        }

        let sessions = try database.read { db in
            try CloudSessionMetadata
                .sessions(
                    workspaceID: canonicalWorkspaceID,
                    isHidden: false
                )
                .fetchAll(db)
        }
        #expect(
            sessions.map(\.id)
                == [
                    CloudCanonicalID.session(
                        accountID: accountID,
                        remoteSessionID: "kept"
                    ),
                ]
        )
    }

    @Test("Complete transcript reconciliation replaces and deletes event parts")
    func completeTranscriptReconciliation() throws {
        let database = try appDatabase()
        try database.write { db in
            _ = try CloudChatPersistence.persist(
                snapshot(accountID: "account", sessionIDs: ["session"]),
                in: db
            )
            _ = try CloudChatPersistence.persist(
                transcript(
                    messages: [
                        userEvent(id: "changed", index: 20, text: "Old"),
                        userEvent(id: "deleted", index: 10, text: "Delete me"),
                    ]
                ),
                in: db
            )
            _ = try CloudChatPersistence.persist(
                transcript(
                    messages: [
                        userEvent(id: "changed", index: 20, text: "New"),
                        unsupportedEvent(id: "formerly-visible", index: 30),
                    ]
                ),
                in: db
            )
        }

        let canonicalSessionID = CloudCanonicalID.session(
            accountID: "account",
            remoteSessionID: "session"
        )
        let messages = try database.read { db in
            try CloudMessageMetadata
                .messages(sessionID: canonicalSessionID)
                .fetchAll(db)
        }
        #expect(messages.map(\.content) == ["New"])
        #expect(
            messages[0].id
                == CloudCanonicalID.message(
                    accountID: "account",
                    remoteSessionID: "session",
                    eventID: "changed",
                    partOrder: 0
                )
        )
    }

    @Test("A duplicate complete event ID keeps only its final projection")
    func duplicateCompleteEventID() throws {
        let database = try appDatabase()
        try database.write { db in
            _ = try CloudChatPersistence.persist(
                snapshot(accountID: "account", sessionIDs: ["session"]),
                in: db
            )
            _ = try CloudChatPersistence.persist(
                transcript(
                    messages: [
                        userEvent(id: "duplicate", index: 1, text: "Obsolete"),
                        unsupportedEvent(id: "duplicate", index: 2),
                    ]
                ),
                in: db
            )
        }

        let messageCount = try database.read { db in
            try CloudMessageMetadata.fetchCount(db)
        }
        #expect(messageCount == 0)
    }

    @Test("A nested Cloud message ID acknowledges its pending send")
    func nestedMessageIDAcknowledgesSend() throws {
        let database = try appDatabase()
        let attemptID = UUID()
        let remoteMessageID = attemptID.uuidString.lowercased()
        let canonicalSessionID = CloudCanonicalID.session(
            accountID: "account",
            remoteSessionID: "session"
        )
        let attempt = MessageDeliveryAttempt(
            attemptID: attemptID,
            route: .cloud,
            accountID: "account",
            credentialGeneration: UUID(),
            canonicalWorkspaceID: "workspace",
            remoteWorkspaceID: "workspace",
            canonicalSessionID: canonicalSessionID,
            remoteSessionID: "session",
            content: "Test",
            model: Session.Model(rawValue: ""),
            isFastModeEnabled: false,
            mode: .sent,
            reasoningEffort: nil,
            submittedDraft: "Test",
            state: .accepted
        )

        try database.write { database in
            _ = try CloudChatPersistence.persist(
                snapshot(accountID: "account", sessionIDs: ["session"]),
                in: database
            )
            try MessageDeliveryAttempt.insert { attempt }.execute(database)
            _ = try CloudChatPersistence.persist(
                transcript(
                    messages: [
                        userEvent(
                            id: "session:1:0",
                            index: 1,
                            text: "Test",
                            remoteMessageID: remoteMessageID
                        ),
                    ]
                ),
                in: database
            )
        }

        let storedAttempt = try database.read { database in
            try MessageDeliveryAttempt.find(attemptID).fetchOne(database)
        }
        #expect(storedAttempt?.deliveryState == .acknowledged)
    }

    @Test(
        "Cloud delivery acknowledgement uses exact fallback identifiers",
        arguments: [
            CloudDeliveryCorrelation.turnID,
            .eventID,
        ]
    )
    func fallbackIdentifierAcknowledgesSend(
        correlation: CloudDeliveryCorrelation
    ) throws {
        let database = try appDatabase()
        let attemptID = UUID()
        let remoteMessageID = attemptID.uuidString.lowercased()
        let canonicalSessionID = CloudCanonicalID.session(
            accountID: "account",
            remoteSessionID: "session"
        )
        let attempt = MessageDeliveryAttempt(
            attemptID: attemptID,
            route: .cloud,
            accountID: "account",
            credentialGeneration: UUID(),
            canonicalWorkspaceID: "workspace",
            remoteWorkspaceID: "workspace",
            canonicalSessionID: canonicalSessionID,
            remoteSessionID: "session",
            content: "Test",
            model: Session.Model(rawValue: ""),
            isFastModeEnabled: false,
            mode: .sent,
            reasoningEffort: nil,
            submittedDraft: "Test",
            state: .accepted
        )
        let event = switch correlation {
        case .turnID:
            userEvent(
                id: "session:1:0",
                index: 1,
                text: "Test",
                remoteMessageID: remoteMessageID,
                includeMessageID: false
            )
        case .eventID:
            userEvent(
                id: remoteMessageID,
                index: 1,
                text: "Test",
                includeTurnID: false
            )
        }

        try database.write { database in
            _ = try CloudChatPersistence.persist(
                snapshot(accountID: "account", sessionIDs: ["session"]),
                in: database
            )
            try MessageDeliveryAttempt.insert { attempt }.execute(database)
            _ = try CloudChatPersistence.persist(
                transcript(messages: [event]),
                in: database
            )
        }

        let storedAttempt = try database.read { database in
            try MessageDeliveryAttempt.find(attemptID).fetchOne(database)
        }
        #expect(storedAttempt?.deliveryState == .acknowledged)
    }

    @Test("Cached transcript evidence reconciles a previously accepted send")
    func cachedTranscriptReconcilesAcceptedSend() throws {
        let database = try appDatabase()
        let attemptID = UUID()
        let remoteMessageID = attemptID.uuidString.lowercased()
        let canonicalSessionID = CloudCanonicalID.session(
            accountID: "account",
            remoteSessionID: "session"
        )
        let attempt = MessageDeliveryAttempt(
            attemptID: attemptID,
            route: .cloud,
            accountID: "account",
            credentialGeneration: UUID(),
            canonicalWorkspaceID: "workspace",
            remoteWorkspaceID: "workspace",
            canonicalSessionID: canonicalSessionID,
            remoteSessionID: "session",
            content: "Test",
            model: Session.Model(rawValue: ""),
            isFastModeEnabled: false,
            mode: .sent,
            reasoningEffort: nil,
            submittedDraft: "Test",
            state: .accepted
        )

        try database.write { database in
            _ = try CloudChatPersistence.persist(
                snapshot(accountID: "account", sessionIDs: ["session"]),
                in: database
            )
            _ = try CloudChatPersistence.persist(
                transcript(
                    messages: [
                        userEvent(
                            id: "session:1:0",
                            index: 1,
                            text: "Test",
                            remoteMessageID: remoteMessageID
                        ),
                    ]
                ),
                in: database
            )
            try MessageDeliveryAttempt.insert { attempt }.execute(database)
            try CloudChatPersistence.reconcileDeliveryAttempts(
                for: canonicalSessionID,
                in: database
            )
        }

        let storedAttempt = try database.read { database in
            try MessageDeliveryAttempt.find(attemptID).fetchOne(database)
        }
        #expect(storedAttempt?.deliveryState == .acknowledged)
    }

    @Test("An unsupported incremental replacement removes obsolete visible parts")
    func unsupportedIncrementalReplacement() throws {
        let database = try appDatabase()
        try database.write { db in
            _ = try CloudChatPersistence.persist(
                snapshot(accountID: "account", sessionIDs: ["session"]),
                in: db
            )
            _ = try CloudChatPersistence.persist(
                transcript(
                    messages: [userEvent(id: "event", index: 1, text: "Visible")]
                ),
                in: db
            )
            _ = try CloudChatPersistence.persist(
                CloudTranscriptUpdate(
                    accountID: "account",
                    sessionID: "session",
                    messages: [unsupportedEvent(id: "event", index: 1)],
                    kind: .incremental,
                    rawCursor: "event"
                ),
                in: db
            )
        }

        let messageCount = try database.read { db in
            try CloudMessageMetadata.fetchCount(db)
        }
        #expect(messageCount == 0)
    }

    @Test("Session refresh preserves a complete durable checkpoint")
    func sessionRefreshPreservesCheckpoint() throws {
        let database = try appDatabase()
        let canonicalSessionID = CloudCanonicalID.session(
            accountID: "account",
            remoteSessionID: "session"
        )
        try database.write { db in
            _ = try CloudChatPersistence.persist(
                snapshot(accountID: "account", sessionIDs: ["session"]),
                in: db
            )
            _ = try CloudChatPersistence.persist(
                transcript(
                    messages: [userEvent(id: "committed", index: 1, text: "Cached")]
                ),
                in: db
            )
            _ = try CloudChatPersistence.persist(
                snapshot(accountID: "account", sessionIDs: ["session"]),
                in: db
            )
        }

        let cache = try database.read { db in
            try CloudChatPersistence.cachedTranscript(
                for: canonicalSessionID,
                in: db
            )
        }
        #expect(cache.messages.map(\.content) == ["Cached"])
        #expect(cache.checkpoint?.accountID == "account")
        #expect(cache.checkpoint?.remoteSessionID == "session")
        #expect(cache.checkpoint?.rawCursor == "committed")
        #expect(cache.checkpoint?.lastFullTranscriptRefreshAt != nil)
    }

    @Test("Projection mismatch keeps cached rows but withholds the checkpoint")
    func projectionMismatch() throws {
        let database = try appDatabase()
        let canonicalSessionID = CloudCanonicalID.session(
            accountID: "account",
            remoteSessionID: "session"
        )
        try database.write { db in
            _ = try CloudChatPersistence.persist(
                snapshot(accountID: "account", sessionIDs: ["session"]),
                in: db
            )
            _ = try CloudChatPersistence.persist(
                transcript(
                    messages: [userEvent(id: "committed", index: 1, text: "Cached")]
                ),
                in: db
            )
            var metadata = try #require(
                try CloudSessionMetadata.find(canonicalSessionID).fetchOne(db)
            )
            metadata.transcriptProjectionVersion =
                CloudTranscriptAdapter.projectionVersion - 1
            try CloudSessionMetadata.upsert { metadata }.execute(db)
        }

        let cache = try database.read { db in
            try CloudChatPersistence.cachedTranscript(
                for: canonicalSessionID,
                in: db
            )
        }
        #expect(cache.messages.map(\.content) == ["Cached"])
        #expect(cache.checkpoint == nil)
    }

    @Test("Unsupported events still advance the raw durable checkpoint")
    func unsupportedEventAdvancesCheckpoint() throws {
        let database = try appDatabase()
        let canonicalSessionID = CloudCanonicalID.session(
            accountID: "account",
            remoteSessionID: "session"
        )
        try database.write { db in
            _ = try CloudChatPersistence.persist(
                snapshot(accountID: "account", sessionIDs: ["session"]),
                in: db
            )
            _ = try CloudChatPersistence.persist(
                transcript(
                    messages: [userEvent(id: "visible", index: 1, text: "Cached")]
                ),
                in: db
            )
            _ = try CloudChatPersistence.persist(
                CloudTranscriptUpdate(
                    accountID: "account",
                    sessionID: "session",
                    messages: [unsupportedEvent(id: "raw-only", index: 2)],
                    kind: .incremental,
                    rawCursor: "raw-only"
                ),
                in: db
            )
        }

        let cache = try database.read { db in
            try CloudChatPersistence.cachedTranscript(
                for: canonicalSessionID,
                in: db
            )
        }
        #expect(cache.messages.map(\.content) == ["Cached"])
        #expect(cache.checkpoint?.rawCursor == "raw-only")
    }

    @Test("Ownership failure leaves the last committed checkpoint unchanged")
    func ownershipFailurePreservesCheckpoint() throws {
        let database = try appDatabase()
        let canonicalSessionID = CloudCanonicalID.session(
            accountID: "account",
            remoteSessionID: "session"
        )
        try database.write { db in
            _ = try CloudChatPersistence.persist(
                snapshot(accountID: "account", sessionIDs: ["session"]),
                in: db
            )
            _ = try CloudChatPersistence.persist(
                transcript(
                    messages: [userEvent(id: "committed", index: 1, text: "Cached")]
                ),
                in: db
            )
        }

        #expect(throws: CloudChatPersistenceError.transcriptOwnershipMismatch) {
            try database.write { db in
                _ = try CloudChatPersistence.persist(
                    CloudTranscriptUpdate(
                        accountID: "other-account",
                        sessionID: "session",
                        messages: [unsupportedEvent(id: "uncommitted", index: 2)],
                        kind: .complete,
                        rawCursor: "uncommitted"
                    ),
                    in: db
                )
            }
        }
        let cache = try database.read { db in
            try CloudChatPersistence.cachedTranscript(
                for: canonicalSessionID,
                in: db
            )
        }
        #expect(cache.checkpoint?.rawCursor == "committed")
        #expect(cache.messages.map(\.content) == ["Cached"])
    }

    @Test("A complete empty transcript remains displayable with a nil cursor")
    func completeEmptyTranscript() throws {
        let database = try appDatabase()
        let canonicalSessionID = CloudCanonicalID.session(
            accountID: "account",
            remoteSessionID: "session"
        )
        try database.write { db in
            _ = try CloudChatPersistence.persist(
                snapshot(accountID: "account", sessionIDs: ["session"]),
                in: db
            )
            _ = try CloudChatPersistence.persist(
                transcript(
                    messages: [userEvent(id: "stale", index: 1, text: "Stale")]
                ),
                in: db
            )
            _ = try CloudChatPersistence.persist(
                transcript(messages: []),
                in: db
            )
        }

        let cache = try database.read { db in
            try CloudChatPersistence.cachedTranscript(
                for: canonicalSessionID,
                in: db
            )
        }
        #expect(cache.messages.isEmpty)
        #expect(cache.checkpoint != nil)
        #expect(cache.checkpoint?.rawCursor == nil)
    }

    @Test("Complete transcript persistence replaces large projections")
    func completeTranscriptReplacesLargeProjection() throws {
        let database = try appDatabase()
        let canonicalSessionID = CloudCanonicalID.session(
            accountID: "account",
            remoteSessionID: "session"
        )
        let initialMessages = (0..<205).map {
            userEvent(
                id: "initial-\($0)",
                index: Double($0),
                text: "Initial \($0)"
            )
        }
        let replacementMessages = (0..<205).map {
            userEvent(
                id: "replacement-\($0)",
                index: Double($0),
                text: "Replacement \($0)"
            )
        }

        try database.write { db in
            _ = try CloudChatPersistence.persist(
                snapshot(accountID: "account", sessionIDs: ["session"]),
                in: db
            )
            _ = try CloudChatPersistence.persist(
                transcript(messages: initialMessages),
                in: db
            )
            _ = try CloudChatPersistence.persist(
                transcript(messages: replacementMessages),
                in: db
            )
        }

        let cache = try database.read { db in
            try CloudChatPersistence.cachedTranscript(
                for: canonicalSessionID,
                in: db
            )
        }
        #expect(cache.messages.count == 205)
        #expect(
            cache.messages.map(\.content)
                == (0..<205).map { "Replacement \($0)" }
        )
        #expect(
            try database.read { db in
                try CloudMessageMetadata.fetchCount(db)
            } == 205
        )
    }

    @Test("Maximum rows per statement respect SQLite's argument limit")
    func maximumRowsPerStatementRespectsArgumentLimit() {
        #expect(
            CloudChatPersistence.maximumRowsPerStatement(
                maximumArgumentCount: 500_000,
                argumentsPerRow: 15
            ) == 33_333
        )
        #expect(
            CloudChatPersistence.maximumRowsPerStatement(
                maximumArgumentCount: 500_000,
                argumentsPerRow: 6
            ) == 83_333
        )
        #expect(
            CloudChatPersistence.maximumRowsPerStatement(
                maximumArgumentCount: 1_000,
                argumentsPerRow: 15
            ) == 66
        )
    }
}

private func snapshot(
    accountID: String,
    sessionIDs: [String],
    effort: String? = "high",
    fastMode: Bool? = nil
) -> CloudWorkspaceSessionSnapshot {
    let date = Date(timeIntervalSince1970: 100)
    let sessions = sessionIDs.map {
        CloudSession(
            id: $0,
            deepLink: URL(string: "https://app.conductor.build")!,
            name: $0,
            model: "gpt-5.6-sol",
            effort: effort,
            agent: "codex",
            fastMode: fastMode
        )
    }
    return CloudWorkspaceSessionSnapshot(
        accountID: accountID,
        workspace: CloudWorkspace(
            id: "workspace",
            name: "Cloud workspace",
            createdAt: date,
            lastActivityAt: date
        ),
        sessions: sessions,
        statuses: Dictionary(
            uniqueKeysWithValues: sessionIDs.map {
                (
                    $0,
                    CloudSessionStatusResponse(
                        workspaceID: "workspace",
                        sessionID: $0,
                        status: .idle,
                        updatedAt: date
                    )
                )
            }
        )
    )
}

private func transcript(
    messages: [CloudTranscriptMessage]
) -> CloudTranscriptUpdate {
    CloudTranscriptUpdate(
        accountID: "account",
        sessionID: "session",
        messages: messages,
        kind: .complete,
        rawCursor: messages.last?.id
    )
}

private func userEvent(
    id: String,
    index: Double,
    text: String,
    remoteMessageID: String? = nil,
    includeMessageID: Bool = true,
    includeTurnID: Bool = true
) -> CloudTranscriptMessage {
    var content: [String: CloudJSONValue] = [
        "type": .string("userMessage"),
        "message": .string(text),
    ]
    if includeTurnID {
        content["turnId"] = .string(remoteMessageID ?? "turn")
    }
    if includeMessageID, let remoteMessageID {
        content["id"] = .string(remoteMessageID)
    }
    return CloudTranscriptMessage(
        id: id,
        sessionID: "session",
        sessionIndex: index,
        type: .init(rawValue: "userMessage"),
        content: .object(content),
        receivedAt: Date(timeIntervalSince1970: index)
    )
}

enum CloudDeliveryCorrelation: Sendable {
    case turnID
    case eventID
}

private func unsupportedEvent(
    id: String,
    index: Double
) -> CloudTranscriptMessage {
    CloudTranscriptMessage(
        id: id,
        sessionID: "session",
        sessionIndex: index,
        type: .init(rawValue: "future"),
        content: .object(["type": .string("future")]),
        receivedAt: Date(timeIntervalSince1970: index)
    )
}
