//
//  DesktopTranscriptStore.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/28/26.
//

import SharedConductorData
import SQLiteData

/// Owns the durable transcript baseline used to render cached desktop content and resume a socket.
///
/// `DesktopClient.messageObservationStream` is the production caller. Keeping cache validation and
/// mutation here ensures the history rows, queue rows, and resume cursor change in one database
/// transaction.
enum DesktopTranscriptStore {
    /// Builds the complete cached snapshot shown before the WebSocket returns its first event.
    ///
    /// The client also resumes from this snapshot's cursor. Returning nil means the cache is
    /// incomplete or disagrees with its cursor, so the caller must connect without `after` and
    /// wait for a full server snapshot.
    static func cachedTranscriptSnapshot(
        workspaceID: Workspace.ID,
        sessionID: Session.ID,
        database: any DatabaseReader
    ) async throws -> MessageSyncEvent? {
        try await database.read { database in
            guard let metadata = try completeTranscriptMetadata(
                workspaceID: workspaceID,
                sessionID: sessionID,
                database: database
            ) else {
                return nil
            }
            let messages = try loadMessagesInResumeOrder(
                sessionID: sessionID,
                database: database
            )
            guard cursorMatchesCompletedHistoryTail(
                metadata.transcriptCursor,
                in: messages
            ) else {
                return nil
            }
            return .snapshot(
                messages.filter { !$0.isQueued },
                cursor: metadata.transcriptCursor,
                queuedMessages: messages
                    .filter(\.isQueued)
                    .sorted(by: isEarlierInQueue)
            )
        }
    }

    /// Unleased entry point used by persistence tests.
    ///
    /// Production WebSocket code must use the connection-lease overload below so an obsolete
    /// connection cannot write after the configured desktop address changes.
    @discardableResult
    static func applySyncEvent(
        _ event: MessageSyncEvent,
        workspaceID: Workspace.ID,
        sessionID: Session.ID,
        database: any DatabaseWriter
    ) async throws -> MessageSyncEvent {
        let event = splitQueueFromLegacySnapshot(event)
        try validateEventEnvelope(event, sessionID: sessionID)
        return try await database.write { database in
            try persistValidatedEvent(
                event,
                workspaceID: workspaceID,
                sessionID: sessionID,
                database: database
            )
        }
    }

    /// Atomically persists one WebSocket event while its connection still owns the cache.
    ///
    /// `DesktopClient.messageObservationStream` calls this for every received envelope. Holding the
    /// lease authority across the synchronous database work gives endpoint changes a clear
    /// boundary: either this event commits for the current desktop, or it throws `staleLease`.
    @discardableResult
    static func applySyncEvent(
        _ event: MessageSyncEvent,
        lease: ConnectionLease,
        database: any DatabaseWriter
    ) async throws -> MessageSyncEvent {
        let event = splitQueueFromLegacySnapshot(event)
        try validateEventEnvelope(event, sessionID: lease.resumeKey.sessionID)
        return try await database.write { database in
            let result = try DesktopLeaseAuthority.shared.withValidLease(lease) {
                try persistValidatedEvent(
                    event,
                    workspaceID: lease.resumeKey.workspaceID,
                    sessionID: lease.resumeKey.sessionID,
                    database: database
                )
            }
            guard let result else {
                throw ApplyError.staleLease
            }
            return result
        }
    }

    /// Rejections that protect the local cache from an invalid envelope or obsolete connection.
    enum ApplyError: Error, Equatable, Sendable {
        /// One envelope tries to upsert the same raw message ID more than once.
        case duplicateMessageID
        /// An incremental event arrived without a complete local history.
        case incompleteBaseline
        /// The advertised cursor is not the stored completed-history tail.
        case invalidCursor
        /// A row carried in `messages` still satisfies the mutable-queue predicate.
        case invalidHistoryMessage
        /// An upserted row belongs to a different session than the route being observed.
        case invalidMessageSession
        /// A row carried in `queuedMessages` does not satisfy the queue predicate.
        case invalidQueuedMessage
        /// The same raw ID appears in both the upsert and deletion sets.
        case messageIDConflict
        /// An upsert would move a globally keyed message row from another session.
        case messageMoved
        /// The target workspace/session tuple is absent or inconsistent.
        case missingSession
        /// The configured endpoint changed before this connection could commit.
        case staleLease
    }
}

private extension DesktopTranscriptStore {
    /// Translates the only legacy envelope shape that can be recovered without ambiguity.
    ///
    /// Old full snapshots mixed queued rows into `messages` and had neither `queued_messages` nor
    /// `cursor`. A full snapshot is authoritative, so we can split it using `Message.isQueued` and
    /// derive the completed-history tail. An incremental event with a nil queue must remain
    /// unchanged because the new protocol defines that value as "queue unchanged."
    static func splitQueueFromLegacySnapshot(
        _ event: MessageSyncEvent
    ) -> MessageSyncEvent {
        guard event.isSnapshot, event.queuedMessages == nil else {
            return event
        }
        let history = event.messages
            .filter { !$0.isQueued }
            .sorted(by: isEarlierInCompletedHistory)
        return MessageSyncEvent(
            isSnapshot: true,
            messages: history,
            deletedMessageIDs: event.deletedMessageIDs,
            cursor: event.cursor ?? history.last?.id,
            queuedMessages: event.messages.filter(\.isQueued)
        )
    }

    /// Applies a validated event inside the caller's `database.write` transaction.
    ///
    /// Complete events replace history; incremental events require a complete baseline for this
    /// session. All row and metadata mutations occur before the final cursor check so any failure
    /// rolls the entire event back.
    static func persistValidatedEvent(
        _ event: MessageSyncEvent,
        workspaceID: Workspace.ID,
        sessionID: Session.ID,
        database: Database
    ) throws -> MessageSyncEvent {
        guard try Workspace.find(workspaceID).fetchOne(database) != nil,
              let session = try Session.find(sessionID).fetchOne(database),
              RawUTF8Key(session.workspaceID) == RawUTF8Key(workspaceID) else {
            throw ApplyError.missingSession
        }

        let oldMetadata = try DesktopTranscriptMetadata.find(sessionID).fetchOne(database)
        let oldMessages = try loadMessagesInResumeOrder(
            sessionID: sessionID,
            database: database
        )
        // A suffix is meaningful only when a prior complete-baseline marker exists and its stored
        // cursor still describes the rows the suffix would extend.
        let hasCompleteBaseline = oldMetadata.map {
            cursorMatchesCompletedHistoryTail(
                $0.transcriptCursor,
                in: oldMessages
            )
        } ?? false
        guard event.isSnapshot || hasCompleteBaseline else {
            throw ApplyError.incompleteBaseline
        }

        let upsertedMessages = event.messages + (event.queuedMessages ?? [])
        try ensureMessagesBelongToSession(
            upsertedMessages,
            sessionID: sessionID,
            database: database
        )
        if event.isSnapshot {
            try deleteCompletedHistoryOmissions(
                retaining: event.messages,
                from: oldMessages,
                database: database
            )
        }
        if !event.deletedMessageIDs.isEmpty {
            try deleteCompletedHistoryRows(
                event.deletedMessageIDs,
                from: oldMessages,
                database: database
            )
        }

        // History is upserted first on purpose. When a queued row becomes completed, this clears
        // its queue markers before authoritative queue-omission reconciliation runs, preventing
        // the newly completed row from being deleted as a stale queue entry.
        if !event.messages.isEmpty {
            try Message.upsert { event.messages }.execute(database)
        }
        if let queuedMessages = event.queuedMessages {
            try reconcileQueue(
                queuedMessages,
                sessionID: sessionID,
                database: database
            )
        }
        guard cursorMatchesCompletedHistoryTail(
            event.cursor,
            in: try loadMessagesInResumeOrder(
                sessionID: sessionID,
                database: database
            )
        ) else {
            throw ApplyError.invalidCursor
        }

        try DesktopTranscriptMetadata.upsert {
            DesktopTranscriptMetadata(
                sessionID: sessionID,
                transcriptCursor: event.cursor
            )
        }
        .execute(database)
        return event
    }

    /// Validates only the event envelope invariants that do not require stored database state.
    ///
    /// This runs before opening a write transaction. Baseline completeness, global message
    /// ownership, and cursor consistency are intentionally checked later by
    /// `persistValidatedEvent`.
    static func validateEventEnvelope(
        _ event: MessageSyncEvent,
        sessionID: Session.ID
    ) throws {
        guard event.messages.allSatisfy({ !$0.isQueued }) else {
            throw ApplyError.invalidHistoryMessage
        }
        guard event.queuedMessages?.allSatisfy(\.isQueued) != false else {
            throw ApplyError.invalidQueuedMessage
        }

        let upsertedMessages = event.messages + (event.queuedMessages ?? [])
        let upsertIDs = upsertedMessages.map { RawUTF8Key($0.id) }
        guard Set(upsertIDs).count == upsertIDs.count else {
            throw ApplyError.duplicateMessageID
        }
        let deletionIDs = Set(event.deletedMessageIDs.map(RawUTF8Key.init))
        guard upsertIDs.allSatisfy({ !deletionIDs.contains($0) }) else {
            throw ApplyError.messageIDConflict
        }
        guard upsertedMessages.allSatisfy({
            $0.sessionID.map(RawUTF8Key.init) == RawUTF8Key(sessionID)
        }) else {
            throw ApplyError.invalidMessageSession
        }
    }

    /// Loads the complete-baseline marker only for the requested workspace/session tuple.
    ///
    /// `sessions.workspaceID` is the canonical source of that relationship; duplicating it in
    /// transcript metadata would create a second value that could disagree.
    static func completeTranscriptMetadata(
        workspaceID: Workspace.ID,
        sessionID: Session.ID,
        database: Database
    ) throws -> DesktopTranscriptMetadata? {
        guard let session = try Session.find(sessionID).fetchOne(database),
              RawUTF8Key(session.workspaceID) == RawUTF8Key(workspaceID) else {
            return nil
        }
        return try DesktopTranscriptMetadata.find(sessionID).fetchOne(database)
    }

    /// Rejects upserts that would overwrite a global message primary key from another session.
    static func ensureMessagesBelongToSession(
        _ messages: [Message],
        sessionID: Session.ID,
        database: Database
    ) throws {
        for message in messages {
            guard let existing = try Message.find(message.id).fetchOne(database) else {
                continue
            }
            guard existing.sessionID.map(RawUTF8Key.init) == RawUTF8Key(sessionID) else {
                throw ApplyError.messageMoved
            }
        }
    }

    /// Deletes completed rows omitted by an authoritative full history snapshot.
    static func deleteCompletedHistoryOmissions(
        retaining messages: [Message],
        from storedMessages: [Message],
        database: Database
    ) throws {
        let messageIDs = Set(messages.map { RawUTF8Key($0.id) })
        for message in storedMessages
        where !message.isQueued && !messageIDs.contains(RawUTF8Key(message.id)) {
            try Message.find(message.id).delete().execute(database)
        }
    }

    /// Applies explicit live-history deletions without allowing that field to mutate queue rows.
    static func deleteCompletedHistoryRows(
        _ messageIDs: [Message.ID],
        from storedMessages: [Message],
        database: Database
    ) throws {
        let deletionIDs = Set(messageIDs.map(RawUTF8Key.init))
        for message in storedMessages
        where !message.isQueued && deletionIDs.contains(RawUTF8Key(message.id)) {
            try Message.find(message.id).delete().execute(database)
        }
    }

    /// Replaces the mutable queue with the supplied authoritative snapshot.
    ///
    /// Every omission is a deletion and every supplied row is upserted. This function is called
    /// only when `queuedMessages` is non-nil; nil means the previous queue remains untouched.
    static func reconcileQueue(
        _ queuedMessages: [Message],
        sessionID: Session.ID,
        database: Database
    ) throws {
        let queuedIDs = Set(queuedMessages.map { RawUTF8Key($0.id) })
        let storedQueuedMessages = try Message
            .where {
                $0.sessionID.eq(sessionID)
                    && $0.sentAt.is(nil)
                    && $0.queueOrder.isNot(nil)
            }
            .fetchAll(database)
        for message in storedQueuedMessages
        where !queuedIDs.contains(RawUTF8Key(message.id)) {
            try Message.find(message.id).delete().execute(database)
        }
        if !queuedMessages.isEmpty {
            try Message.upsert { queuedMessages }.execute(database)
        }
    }

    /// Loads one session in the exact order used to define the completed-history cursor.
    static func loadMessagesInResumeOrder(
        sessionID: Session.ID,
        database: Database
    ) throws -> [Message] {
        try Message
            .where { $0.sessionID.eq(sessionID) }
            .order(by: \.createdAt)
            .fetchAll(database)
            .sorted(by: isEarlierInCompletedHistory)
    }

    /// Matches the server's actual-send-time order used to define resume suffixes.
    static func isEarlierInCompletedHistory(_ lhs: Message, _ rhs: Message) -> Bool {
        if lhs.sentAt != rhs.sentAt {
            switch (lhs.sentAt, rhs.sentAt) {
            case let (lhs?, rhs?):
                return lhs < rhs
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                break
            }
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return RawUTF8Key(lhs.id) < RawUTF8Key(rhs.id)
    }

    /// Orders queued rows for immediate cached display with deterministic malformed-data fallbacks.
    static func isEarlierInQueue(_ lhs: Message, _ rhs: Message) -> Bool {
        if let lhsOrder = lhs.queueOrder,
           let rhsOrder = rhs.queueOrder,
           lhsOrder != rhsOrder {
            return lhsOrder < rhsOrder
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return RawUTF8Key(lhs.id) < RawUTF8Key(rhs.id)
    }

    /// Confirms that `after=<cursor>` would resume from this cache's actual history tail.
    ///
    /// A nil cursor is valid only for empty completed history. Any other mismatch makes the
    /// baseline unusable and forces the WebSocket caller to recover with a complete snapshot.
    static func cursorMatchesCompletedHistoryTail(
        _ cursor: Message.ID?,
        in messages: [Message]
    ) -> Bool {
        let historyTailID = messages.last(where: { !$0.isQueued })?.id
        switch (cursor, historyTailID) {
        case (nil, nil):
            return true
        case let (cursor?, historyTailID?):
            return RawUTF8Key(cursor) == RawUTF8Key(historyTailID)
        case (.some, nil), (nil, .some):
            return false
        }
    }
}
