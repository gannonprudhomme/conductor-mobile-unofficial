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
    text: String
) -> CloudTranscriptMessage {
    CloudTranscriptMessage(
        id: id,
        sessionID: "session",
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
