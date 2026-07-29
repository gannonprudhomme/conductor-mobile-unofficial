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
    @Test("Desktop visibility wins when Cloud omits archive state")
    func desktopVisibilityWinsWithoutCloudArchiveState() throws {
        let database = try appDatabase()
        let desktopSessions = [
            Session.preview(
                id: "active",
                workspaceID: "workspace",
                isHidden: false
            ),
            Session.preview(
                id: "archived",
                workspaceID: "workspace",
                isHidden: true
            ),
        ]

        try database.write { database in
            try Session.upsert { desktopSessions }.execute(database)
            _ = try CloudChatPersistence.persist(
                snapshot(
                    accountID: "account",
                    sessionIDs: desktopSessions.map(\.id)
                ),
                in: database
            )
        }

        let activeSessions = try database.read { database in
            try CloudSessionMetadata
                .sessions(workspaceID: "workspace", isHidden: false)
                .fetchAll(database)
        }
        let archivedSessions = try database.read { database in
            try CloudSessionMetadata
                .sessions(workspaceID: "workspace", isHidden: true)
                .fetchAll(database)
        }

        #expect(activeSessions.map(\.title) == ["active"])
        #expect(archivedSessions.map(\.title) == ["archived"])
    }

    @Test("Desktop visibility updates survive later Cloud refreshes")
    func desktopVisibilityUpdatesSurviveCloudRefresh() throws {
        let database = try appDatabase()
        let cloudSnapshot = snapshot(
            accountID: "account",
            sessionIDs: ["active", "archived"]
        )
        let archivedDesktopSession = Session.preview(
            id: "archived",
            workspaceID: "workspace",
            isHidden: true
        )

        let reconciledSessions = try database.write { database in
            _ = try CloudChatPersistence.persist(cloudSnapshot, in: database)
            _ = try CloudChatPersistence.reconcileSessionVisibility(
                from: [archivedDesktopSession],
                workspaceID: "workspace",
                in: database
            )
            return try CloudChatPersistence.persist(cloudSnapshot, in: database)
        }

        #expect(reconciledSessions.map(\.title) == ["active", "archived"])
        #expect(reconciledSessions.map(\.isHidden) == [false, true])
    }

    @Test("Desktop reconciliation changes only Cloud visibility")
    func desktopReconciliationChangesOnlyVisibility() throws {
        let database = try appDatabase()
        let cloudSession = try database.write { database in
            try #require(
                CloudChatPersistence.persist(
                    snapshot(
                        accountID: "account",
                        sessionIDs: ["session"]
                    ),
                    in: database
                )
                .first
            )
        }
        let desktopSession = Session.preview(
            id: "session",
            workspaceID: "workspace",
            title: "Desktop title",
            agentType: .claude,
            isHidden: true,
            createdAt: "2001-01-01T00:00:00.000Z",
            updatedAt: "2002-01-01T00:00:00.000Z",
            lastUserMessageAt: "2003-01-01T00:00:00.000Z",
            status: .working,
            model: .opus,
            unreadCount: 99,
            freshlyCompacted: 1,
            contextTokenCount: 123,
            codexThinkingLevel: nil,
            isFastModeEnabled: true,
            claudeEffortLevel: .ultra
        )

        let reconciledSession = try database.write { database in
            try #require(
                CloudChatPersistence.reconcileSessionVisibility(
                    from: [desktopSession],
                    workspaceID: "workspace",
                    in: database
                )
                .first
            )
        }
        var expectedSession = cloudSession
        expectedSession.isHidden = true

        #expect(reconciledSession == expectedSession)
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

    @Test("Stale-session cleanup deletes canonical transcript bodies")
    func staleSessionCleanupDeletesMessages() throws {
        let database = try appDatabase()
        let desktopMessage = Message(
            id: "desktop-message",
            sessionID: "desktop-session",
            role: .user,
            content: "Desktop",
            createdAt: .distantPast
        )
        let cloudMessageID = CloudCanonicalID.message(
            accountID: "account",
            remoteSessionID: "stale",
            eventID: "cloud-event",
            partOrder: 0
        )

        try database.write { db in
            try Message.insert { desktopMessage }.execute(db)
            _ = try CloudChatPersistence.persist(
                snapshot(
                    accountID: "account",
                    sessionIDs: ["kept", "stale"]
                ),
                in: db
            )
            _ = try CloudChatPersistence.persist(
                transcript(
                    sessionID: "stale",
                    messages: [
                        userEvent(
                            id: "cloud-event",
                            sessionID: "stale",
                            index: 1,
                            text: "Cloud"
                        ),
                    ]
                ),
                in: db
            )
            _ = try CloudChatPersistence.persist(
                snapshot(accountID: "account", sessionIDs: ["kept"]),
                in: db
            )
        }

        let storedMessages = try database.read { db in
            (
                try Message.find(cloudMessageID).fetchOne(db),
                try Message.find(desktopMessage.id).fetchOne(db)
            )
        }
        #expect(storedMessages.0 == nil)
        #expect(storedMessages.1 == desktopMessage)
    }

    @Test("Logout cleanup deletes Cloud transcripts and preserves Desktop messages")
    func logoutDeletesCloudMessages() throws {
        let database = try appDatabase()
        let desktopMessage = Message(
            id: "desktop-message",
            sessionID: "desktop-session",
            role: .user,
            content: "Desktop",
            createdAt: .distantPast
        )
        let cloudMessageID = CloudCanonicalID.message(
            accountID: "account",
            remoteSessionID: "session",
            eventID: "cloud-event",
            partOrder: 0
        )

        try database.write { db in
            try Message.insert { desktopMessage }.execute(db)
            _ = try CloudChatPersistence.persist(
                snapshot(accountID: "account", sessionIDs: ["session"]),
                in: db
            )
            _ = try CloudChatPersistence.persist(
                transcript(
                    messages: [
                        userEvent(
                            id: "cloud-event",
                            index: 1,
                            text: "Cloud"
                        ),
                    ]
                ),
                in: db
            )
            try CloudChatPersistence.clearCachedRows(in: db)
        }

        let storedMessages = try database.read { db in
            (
                try Message.find(cloudMessageID).fetchOne(db),
                try Message.find(desktopMessage.id).fetchOne(db)
            )
        }
        #expect(storedMessages.0 == nil)
        #expect(storedMessages.1 == desktopMessage)
    }

    @Test("A failed fresh status refresh preserves the durable known status")
    func missingStatusPreservesDurableStatus() throws {
        let database = try appDatabase()
        let knownSnapshot = snapshot(
            accountID: "account",
            sessionIDs: ["session"]
        )
        let missingStatusSnapshot = CloudWorkspaceSessionSnapshot(
            accountID: knownSnapshot.accountID,
            workspace: knownSnapshot.workspace,
            sessions: knownSnapshot.sessions,
            statuses: [:]
        )

        let session = try database.write { db in
            _ = try CloudChatPersistence.persist(knownSnapshot, in: db)
            _ = try CloudChatPersistence.persist(missingStatusSnapshot, in: db)
            return try #require(
                try Session
                    .find(
                        CloudCanonicalID.session(
                            accountID: "account",
                            remoteSessionID: "session"
                        )
                    )
                    .fetchOne(db)
            )
        }

        #expect(session.status == .idle)
    }

    @Test("Contract models infer agents and preserve raw effort without agent")
    func modelInferencePreservesEffort() throws {
        let database = try appDatabase()
        let date = Date(timeIntervalSince1970: 100)
        let cloudSessions = [
            CloudSession(
                id: "claude",
                deepLink: URL(string: "https://app.conductor.build")!,
                model: "opus-4-8",
                effort: "future-claude"
            ),
            CloudSession(
                id: "codex",
                deepLink: URL(string: "https://app.conductor.build")!,
                resolvedModel: "gpt-5.2-codex",
                effort: "future-codex"
            ),
            CloudSession(
                id: "resolved-codex",
                deepLink: URL(string: "https://app.conductor.build")!,
                model: "default",
                resolvedModel: "gpt-5.2-codex",
                effort: "future-resolved-codex"
            ),
        ]
        let snapshot = CloudWorkspaceSessionSnapshot(
            accountID: "account",
            workspace: CloudWorkspace(
                id: "workspace",
                name: "Cloud workspace",
                createdAt: date
            ),
            sessions: cloudSessions,
            statuses: [:]
        )

        let sessions = try database.write { db in
            try CloudChatPersistence.persist(snapshot, in: db)
        }

        #expect(sessions[0].agentType == .claude)
        #expect(sessions[0].claudeEffortLevel?.rawValue == "future-claude")
        #expect(sessions[1].agentType == .codex)
        #expect(sessions[1].codexThinkingLevel?.rawValue == "future-codex")
        #expect(sessions[2].model.rawValue == "default")
        #expect(sessions[2].agentType == .codex)
        #expect(
            sessions[2].codexThinkingLevel?.rawValue
                == "future-resolved-codex"
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
        #expect(
            cache.checkpoint
                == CloudTranscriptCheckpoint(
                    accountID: "account",
                    remoteSessionID: "session",
                    rawCursor: "committed"
                )
        )
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
            metadata.transcriptProjectionVersion = 0
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
    sessionIDs: [String]
) -> CloudWorkspaceSessionSnapshot {
    let date = Date(timeIntervalSince1970: 100)
    let sessions = sessionIDs.map {
        CloudSession(
            id: $0,
            deepLink: URL(string: "https://app.conductor.build")!,
            name: $0,
            model: "gpt-5.6-sol",
            effort: "high",
            agent: "codex"
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
    accountID: String = "account",
    sessionID: String = "session",
    messages: [CloudTranscriptMessage]
) -> CloudTranscriptUpdate {
    CloudTranscriptUpdate(
        accountID: accountID,
        sessionID: sessionID,
        messages: messages,
        kind: .complete,
        rawCursor: messages.last?.id
    )
}

private func userEvent(
    id: String,
    sessionID: String = "session",
    index: Double,
    text: String
) -> CloudTranscriptMessage {
    CloudTranscriptMessage(
        id: id,
        sessionID: sessionID,
        sessionIndex: index,
        type: .init(rawValue: "userMessage"),
        content: .object([
            "type": .string("userMessage"),
            "message": .string(text),
            "turnId": .string("turn"),
        ]),
        receivedAt: Date(timeIntervalSince1970: index)
    )
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
