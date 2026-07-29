//
//  DesktopTranscriptStoreTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/28/26.
//

import Foundation
import SharedConductorData
import SQLiteData
@testable import ConductorMobileData
import Testing

struct DesktopTranscriptStoreTests {
    @Test("Legacy complete snapshots reconcile mixed history and queue rows")
    func legacySnapshot() async throws {
        let database = try appDatabase()
        let (workspace, session) = try await seed(database: database)
        let completed = message(id: "completed", sessionID: session.id, seconds: 1)
        let queued = message(
            id: "queued",
            sessionID: session.id,
            seconds: 2,
            queueOrder: 0
        )
        let event = MessageSyncEvent.snapshot([completed, queued])

        let applied = try await DesktopTranscriptStore.applySyncEvent(
            event,
            workspaceID: workspace.id,
            sessionID: session.id,
            database: database
        )

        #expect(applied.messages == [completed])
        #expect(applied.queuedMessages == [queued])
        #expect(applied.cursor == completed.id)
        let cached = try #require(
            try await DesktopTranscriptStore.cachedTranscriptSnapshot(
                workspaceID: workspace.id,
                sessionID: session.id,
                database: database
            )
        )
        #expect(cached.messages == [completed])
        #expect(cached.queuedMessages == [queued])
    }

    @Test("Complete and incremental events atomically maintain history, queue, and cursor")
    func completeAndIncrementalEvents() async throws {
        let database = try appDatabase()
        let (workspace, session) = try await seed(database: database)
        let first = message(id: "one", sessionID: session.id, seconds: 1)
        let second = message(id: "two", sessionID: session.id, seconds: 2)
        let queued = message(
            id: "queued",
            sessionID: session.id,
            seconds: 3,
            queueOrder: 0
        )

        try await DesktopTranscriptStore.applySyncEvent(
            .snapshot([first], cursor: first.id, queuedMessages: [queued]),
            workspaceID: workspace.id,
            sessionID: session.id,
            database: database
        )
        try await DesktopTranscriptStore.applySyncEvent(
            .changes(
                upserting: [second],
                deleting: [first.id],
                cursor: second.id,
                queuedMessages: []
            ),
            workspaceID: workspace.id,
            sessionID: session.id,
            database: database
        )

        let cached = try #require(
            try await DesktopTranscriptStore.cachedTranscriptSnapshot(
                workspaceID: workspace.id,
                sessionID: session.id,
                database: database
            )
        )
        #expect(cached.isSnapshot)
        #expect(cached.messages.map(\.id) == [second.id])
        #expect(cached.queuedMessages == [])
        #expect(cached.cursor == second.id)
    }

    @Test("A late cursor failure rolls back history, queue, and metadata together")
    func invalidCursorRollsBackEvent() async throws {
        let database = try appDatabase()
        let (workspace, session) = try await seed(database: database)
        let first = message(id: "one", sessionID: session.id, seconds: 1)
        let second = message(id: "two", sessionID: session.id, seconds: 2)
        let queued = message(
            id: "queued",
            sessionID: session.id,
            seconds: 3,
            queueOrder: 0
        )
        try await DesktopTranscriptStore.applySyncEvent(
            .snapshot([first], cursor: first.id, queuedMessages: [queued]),
            workspaceID: workspace.id,
            sessionID: session.id,
            database: database
        )
        let baseline = try #require(
            try await DesktopTranscriptStore.cachedTranscriptSnapshot(
                workspaceID: workspace.id,
                sessionID: session.id,
                database: database
            )
        )

        await #expect(throws: DesktopTranscriptStore.ApplyError.invalidCursor) {
            try await DesktopTranscriptStore.applySyncEvent(
                .changes(
                    upserting: [second],
                    deleting: [first.id],
                    cursor: first.id,
                    queuedMessages: []
                ),
                workspaceID: workspace.id,
                sessionID: session.id,
                database: database
            )
        }

        #expect(
            try await DesktopTranscriptStore.cachedTranscriptSnapshot(
                workspaceID: workspace.id,
                sessionID: session.id,
                database: database
            ) == baseline
        )
    }

    @Test("Invalid envelope partitions and identifiers are rejected before persistence")
    func invalidEventEnvelope() async throws {
        let database = try appDatabase()
        let (workspace, session) = try await seed(database: database)
        let completed = message(id: "completed", sessionID: session.id, seconds: 1)
        let queued = message(
            id: "queued",
            sessionID: session.id,
            seconds: 2,
            queueOrder: 0
        )
        let wrongSession = message(id: "wrong", sessionID: "other", seconds: 3)
        let otherSession = Session.preview(
            id: "other-session",
            workspaceID: workspace.id
        )
        let existingOtherMessage = message(
            id: "global-id",
            sessionID: otherSession.id,
            seconds: 4
        )
        try await database.write { database in
            try Session.insert { otherSession }.execute(database)
            try Message.insert { existingOtherMessage }.execute(database)
        }

        await #expect(throws: DesktopTranscriptStore.ApplyError.invalidHistoryMessage) {
            try await DesktopTranscriptStore.applySyncEvent(
                .snapshot([queued], queuedMessages: []),
                workspaceID: workspace.id,
                sessionID: session.id,
                database: database
            )
        }
        await #expect(throws: DesktopTranscriptStore.ApplyError.invalidQueuedMessage) {
            try await DesktopTranscriptStore.applySyncEvent(
                .snapshot([], queuedMessages: [completed]),
                workspaceID: workspace.id,
                sessionID: session.id,
                database: database
            )
        }
        await #expect(throws: DesktopTranscriptStore.ApplyError.duplicateMessageID) {
            try await DesktopTranscriptStore.applySyncEvent(
                .snapshot(
                    [completed, completed],
                    cursor: completed.id,
                    queuedMessages: []
                ),
                workspaceID: workspace.id,
                sessionID: session.id,
                database: database
            )
        }
        await #expect(throws: DesktopTranscriptStore.ApplyError.messageIDConflict) {
            try await DesktopTranscriptStore.applySyncEvent(
                MessageSyncEvent(
                    isSnapshot: true,
                    messages: [completed],
                    deletedMessageIDs: [completed.id],
                    cursor: completed.id,
                    queuedMessages: []
                ),
                workspaceID: workspace.id,
                sessionID: session.id,
                database: database
            )
        }
        await #expect(throws: DesktopTranscriptStore.ApplyError.invalidMessageSession) {
            try await DesktopTranscriptStore.applySyncEvent(
                .snapshot([wrongSession], cursor: wrongSession.id, queuedMessages: []),
                workspaceID: workspace.id,
                sessionID: session.id,
                database: database
            )
        }
        await #expect(throws: DesktopTranscriptStore.ApplyError.invalidCursor) {
            try await DesktopTranscriptStore.applySyncEvent(
                .snapshot([completed], queuedMessages: []),
                workspaceID: workspace.id,
                sessionID: session.id,
                database: database
            )
        }
        let movedMessage = message(
            id: existingOtherMessage.id,
            sessionID: session.id,
            seconds: 4
        )
        await #expect(throws: DesktopTranscriptStore.ApplyError.messageMoved) {
            try await DesktopTranscriptStore.applySyncEvent(
                .snapshot(
                    [movedMessage],
                    cursor: movedMessage.id,
                    queuedMessages: []
                ),
                workspaceID: workspace.id,
                sessionID: session.id,
                database: database
            )
        }
        #expect(try await storedMessages(sessionID: session.id, database: database).isEmpty)
    }

    @Test("Queue snapshots delete omissions without deleting completed history")
    func queueReconciliation() async throws {
        let database = try appDatabase()
        let (workspace, session) = try await seed(database: database)
        let completed = message(id: "completed", sessionID: session.id, seconds: 1)
        let firstQueued = message(
            id: "first-queued",
            sessionID: session.id,
            seconds: 2,
            queueOrder: 0
        )
        var editedQueued = message(
            id: "second-queued",
            sessionID: session.id,
            seconds: 3,
            queueOrder: 1
        )

        try await DesktopTranscriptStore.applySyncEvent(
            .snapshot(
                [completed],
                cursor: completed.id,
                queuedMessages: [firstQueued, editedQueued]
            ),
            workspaceID: workspace.id,
            sessionID: session.id,
            database: database
        )
        editedQueued.content = "Edited"
        editedQueued.queueOrder = 0
        try await DesktopTranscriptStore.applySyncEvent(
            .changes(
                cursor: completed.id,
                queuedMessages: [editedQueued]
            ),
            workspaceID: workspace.id,
            sessionID: session.id,
            database: database
        )

        let messages = try await storedMessages(sessionID: session.id, database: database)
        #expect(messages.map(\.id) == [completed.id, editedQueued.id])
        #expect(messages.first?.isQueued == false)
        #expect(messages.last?.content == "Edited")
        #expect(messages.last?.queueOrder == 0)
    }

    @Test("A queued-to-completed transition reconciles the queue and upserts history")
    func queuedToCompletedTransition() async throws {
        let database = try appDatabase()
        let (workspace, session) = try await seed(database: database)
        let queued = message(
            id: "transitioning",
            sessionID: session.id,
            seconds: 1,
            queueOrder: 0
        )
        try await DesktopTranscriptStore.applySyncEvent(
            .snapshot([], queuedMessages: [queued]),
            workspaceID: workspace.id,
            sessionID: session.id,
            database: database
        )

        var completed = queued
        completed.sentAt = Date(timeIntervalSince1970: 2)
        completed.queueOrder = nil
        try await DesktopTranscriptStore.applySyncEvent(
            .changes(
                upserting: [completed],
                cursor: completed.id,
                queuedMessages: []
            ),
            workspaceID: workspace.id,
            sessionID: session.id,
            database: database
        )

        let cached = try #require(
            try await DesktopTranscriptStore.cachedTranscriptSnapshot(
                workspaceID: workspace.id,
                sessionID: session.id,
                database: database
            )
        )
        #expect(cached.messages == [completed])
        #expect(cached.queuedMessages == [])
        #expect(cached.cursor == completed.id)
    }

    @Test("Incremental events without a complete baseline require recovery")
    func incompleteBaseline() async throws {
        let database = try appDatabase()
        let (workspace, session) = try await seed(database: database)
        let message = message(id: "one", sessionID: session.id, seconds: 1)

        await #expect(throws: DesktopTranscriptStore.ApplyError.incompleteBaseline) {
            try await DesktopTranscriptStore.applySyncEvent(
                .changes(upserting: [message], cursor: message.id),
                workspaceID: workspace.id,
                sessionID: session.id,
                database: database
            )
        }
        #expect(try await storedMessages(sessionID: session.id, database: database).isEmpty)

        try await DesktopTranscriptStore.applySyncEvent(
            .snapshot([message], cursor: message.id, queuedMessages: []),
            workspaceID: workspace.id,
            sessionID: session.id,
            database: database
        )

        try await database.write { database in
            try database.execute(
                sql: """
                    UPDATE desktop_transcript_metadata
                    SET transcript_cursor = 'missing'
                    WHERE session_id = ?
                    """,
                arguments: [session.id]
            )
        }
        #expect(
            try await DesktopTranscriptStore.cachedTranscriptSnapshot(
                workspaceID: workspace.id,
                sessionID: session.id,
                database: database
            ) == nil
        )
        await #expect(throws: DesktopTranscriptStore.ApplyError.incompleteBaseline) {
            try await DesktopTranscriptStore.applySyncEvent(
                .changes(cursor: message.id, queuedMessages: []),
                workspaceID: workspace.id,
                sessionID: session.id,
                database: database
            )
        }
    }

    @Test("Stale leases cannot mutate a transcript cache")
    func staleLease() async throws {
        let database = try appDatabase()
        let (workspace, session) = try await seed(database: database)
        let firstLifecycle = DesktopLeaseAuthority.shared.transition(
            to: "stale-\(UUID().uuidString).example:3768"
        )
        let endpoint = try #require(firstLifecycle.configuredEndpoint)
        let originalMessage = message(
            id: "original",
            sessionID: session.id,
            seconds: 1
        )
        try await DesktopTranscriptStore.applySyncEvent(
            .snapshot(
                [originalMessage],
                cursor: originalMessage.id,
                queuedMessages: []
            ),
            workspaceID: workspace.id,
            sessionID: session.id,
            database: database
        )
        let lease = try #require(
            DesktopLeaseAuthority.shared.beginConnection(
                resumeKey: ResumeKey(
                    workspaceID: workspace.id,
                    sessionID: session.id
                ),
                endpointEpoch: firstLifecycle.endpointEpoch
            )
        )
        _ = DesktopLeaseAuthority.shared.transition(
            to: "replacement-\(UUID().uuidString).example:3768"
        )
        #expect(
            try await DesktopTranscriptStore.cachedTranscriptSnapshot(
                workspaceID: workspace.id,
                sessionID: session.id,
                database: database
            )?.messages == [originalMessage]
        )
        let replacementMessage = message(
            id: "replacement",
            sessionID: session.id,
            seconds: 2
        )

        await #expect(throws: DesktopTranscriptStore.ApplyError.staleLease) {
            try await DesktopTranscriptStore.applySyncEvent(
                .snapshot(
                    [replacementMessage],
                    cursor: replacementMessage.id,
                    queuedMessages: []
                ),
                lease: lease,
                database: database
            )
        }
        #expect(
            try await storedMessages(sessionID: session.id, database: database)
                == [originalMessage]
        )
    }

    @Test("Event validation compares identifiers by raw UTF-8 bytes")
    func rawIdentifierValidation() async throws {
        let database = try appDatabase()
        let (workspace, session) = try await seed(database: database)
        let composed = message(
            id: "message-\u{e9}",
            sessionID: session.id,
            seconds: 1
        )
        let decomposed = message(
            id: "message-e\u{301}",
            sessionID: session.id,
            seconds: 1
        )

        try await DesktopTranscriptStore.applySyncEvent(
            .snapshot(
                [composed, decomposed],
                cursor: composed.id,
                queuedMessages: []
            ),
            workspaceID: workspace.id,
            sessionID: session.id,
            database: database
        )
        #expect(try await storedMessages(sessionID: session.id, database: database).count == 2)
    }
}

private extension DesktopTranscriptStoreTests {
    func seed(
        database: any DatabaseWriter
    ) async throws -> (Workspace, Session) {
        let workspace = Workspace.preview()
        let session = Session.preview()
        try await database.write { database in
            try Workspace.insert { workspace }.execute(database)
            try Session.insert { session }.execute(database)
        }
        return (workspace, session)
    }

    func message(
        id: Message.ID,
        sessionID: Session.ID,
        seconds: TimeInterval,
        queueOrder: Int? = nil
    ) -> Message {
        Message(
            id: id,
            sessionID: sessionID,
            role: .user,
            content: id,
            createdAt: Date(timeIntervalSince1970: seconds),
            sentAt: queueOrder == nil
                ? Date(timeIntervalSince1970: seconds)
                : nil,
            queueOrder: queueOrder
        )
    }

    func storedMessages(
        sessionID: Session.ID,
        database: any DatabaseReader
    ) async throws -> [Message] {
        try await database.read { database in
            try Message
                .where { $0.sessionID.eq(sessionID) }
                .order(by: \.createdAt)
                .fetchAll(database)
        }
    }
}

private extension DesktopEndpointLifecycle {
    var configuredEndpoint: DesktopEndpoint? {
        guard case let .configured(endpoint, _) = self else {
            return nil
        }
        return endpoint
    }
}
