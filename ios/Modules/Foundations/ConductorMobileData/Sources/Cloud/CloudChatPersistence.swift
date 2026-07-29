//
//  CloudChatPersistence.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/28/26.
//

import ConductorCloud
import Foundation
import SharedConductorData
import SQLiteData

public enum CloudChatPersistenceError: Error, Equatable, LocalizedError, Sendable {
    case transcriptOwnershipMismatch

    public var errorDescription: String? {
        "The Cloud transcript no longer belongs to this cached session."
    }
}

public struct CloudCachedTranscript: Equatable, Sendable {
    public let remoteSessionID: String
    public let messages: [Message]
    public let checkpoint: CloudTranscriptCheckpoint?

    public init(
        remoteSessionID: String,
        messages: [Message],
        checkpoint: CloudTranscriptCheckpoint?
    ) {
        self.remoteSessionID = remoteSessionID
        self.messages = messages
        self.checkpoint = checkpoint
    }
}

public enum CloudChatPersistence {
    // Multi-row upserts bind every writable column once per row. Keep these
    // counts aligned with Message and CloudMessageMetadata so a batch never
    // exceeds the SQLite connection's runtime variable limit.
    private static let messageArgumentsPerRow = 15
    private static let messageMetadataArgumentsPerRow = 6

    public static func persist(
        _ snapshot: CloudWorkspaceSessionSnapshot,
        in database: Database
    ) throws -> [Session] {
        let generation = UUID().uuidString
        let canonicalWorkspaceID = try CloudWorkspaceMetadata
            .where {
                $0.accountID.eq(snapshot.accountID)
                    && $0.remoteWorkspaceID.eq(snapshot.workspace.id)
            }
            .fetchOne(database)?
            .workspaceID
            ?? snapshot.workspace.id
        try clearCachedRows(
            in: database,
            keepingAccountID: snapshot.accountID
        )

        var canonicalSessions: [Session] = []
        for (listOrder, cloudSession) in snapshot.sessions.enumerated() {
            let canonicalID = CloudCanonicalID.session(
                accountID: snapshot.accountID,
                remoteSessionID: cloudSession.id
            )
            let existing = try Session.find(canonicalID).fetchOne(database)
            let existingMetadata = try CloudSessionMetadata
                .find(canonicalID)
                .fetchOne(database)
            let status = snapshot.statuses[cloudSession.id]
            let attempts = try pendingAttempts(
                accountID: snapshot.accountID,
                canonicalSessionID: canonicalID,
                in: database
            )
            var finalizedAttemptIDs: [UUID] = []
            var session = canonicalSession(
                cloudSession,
                canonicalID: canonicalID,
                workspaceID: canonicalWorkspaceID,
                status: status,
                existing: existing
            )
            for attempt in attempts {
                switch attempt.mutationOperation {
                case .createSession:
                    if try CloudPendingMutation.compareAndSetState(
                        attemptID: attempt.attemptID,
                        from: attempt.mutationState,
                        to: .acknowledged,
                        at: Date(),
                        in: database
                    ) {
                        finalizedAttemptIDs.append(attempt.attemptID)
                    }

                case .renameSession:
                    let request = try attempt.request(
                        as: CloudRenameSessionRequest.self
                    )
                    session.title = request.name
                    if cloudSession.name == request.name {
                        if try CloudPendingMutation.compareAndSetState(
                            attemptID: attempt.attemptID,
                            from: attempt.mutationState,
                            to: .acknowledged,
                            at: Date(),
                            in: database
                        ) {
                            finalizedAttemptIDs.append(attempt.attemptID)
                        }
                    }

                case .archiveSession:
                    session.isHidden = true
                    if cloudSession.archivedAt != nil {
                        if try CloudPendingMutation.compareAndSetState(
                            attemptID: attempt.attemptID,
                            from: attempt.mutationState,
                            to: .acknowledged,
                            at: Date(),
                            in: database
                        ) {
                            finalizedAttemptIDs.append(attempt.attemptID)
                        }
                    }

                case .cancelSession:
                    if attempt.mutationState == .accepted,
                       status?.status == .idle
                        || status?.status == .error {
                        if try CloudPendingMutation.compareAndSetState(
                            attemptID: attempt.attemptID,
                            from: attempt.mutationState,
                            to: .acknowledged,
                            at: Date(),
                            in: database
                        ) {
                            finalizedAttemptIDs.append(attempt.attemptID)
                        }
                    }

                default:
                    break
                }
            }
            try Session.upsert { session }.execute(database)
            try CloudSessionMetadata
                .upsert {
                    CloudSessionMetadata(
                        canonicalSessionID: canonicalID,
                        cloudSessionID: cloudSession.id,
                        workspaceID: canonicalWorkspaceID,
                        accountID: snapshot.accountID,
                        listOrder: listOrder,
                        refreshGeneration: generation,
                        transcriptCursor: existingMetadata?.transcriptCursor,
                        hasCompleteTranscript: existingMetadata?.hasCompleteTranscript
                            ?? false,
                        transcriptProjectionVersion: existingMetadata?
                            .transcriptProjectionVersion
                            ?? 0,
                        lastFullTranscriptRefreshAt: existingMetadata?
                            .lastFullTranscriptRefreshAt
                    )
                }
                .execute(database)
            for attemptID in finalizedAttemptIDs {
                try CloudPendingMutation.find(attemptID)
                    .delete()
                    .execute(database)
            }
            canonicalSessions.append(session)
        }

        let staleMetadata = try CloudSessionMetadata
            .where {
                $0.workspaceID.eq(canonicalWorkspaceID)
                    && $0.accountID.eq(snapshot.accountID)
                    && $0.refreshGeneration.neq(generation)
            }
            .fetchAll(database)
        try reconcileStaleSessions(
            staleMetadata,
            accountID: snapshot.accountID,
            in: database
        )
        return canonicalSessions
    }

    /// Applies Desktop-only visibility changes to Cloud canonical session rows.
    ///
    /// Raw Desktop identifiers are used only for matching and are never persisted as duplicates.
    public static func reconcileSessionVisibility(
        from desktopSessions: [Session],
        canonicalWorkspaceID: Workspace.ID,
        remoteWorkspaceID: Workspace.ID,
        in database: Database
    ) throws -> [Session] {
        let desktopSessionsByID = Dictionary(
            uniqueKeysWithValues: desktopSessions
                .filter { $0.workspaceID == remoteWorkspaceID }
                .map { ($0.id, $0) }
        )
        let metadata = try CloudSessionMetadata
            .where { $0.workspaceID.eq(canonicalWorkspaceID) }
            .order(by: \.listOrder)
            .fetchAll(database)

        var canonicalSessions: [Session] = []
        for item in metadata {
            guard var canonicalSession = try Session
                .find(item.canonicalSessionID)
                .fetchOne(database) else {
                continue
            }
            if let desktopSession = desktopSessionsByID[item.cloudSessionID],
               canonicalSession.isHidden != desktopSession.isHidden {
                canonicalSession.isHidden = desktopSession.isHidden
                try Session.upsert { canonicalSession }.execute(database)
            }
            canonicalSessions.append(canonicalSession)
        }
        return canonicalSessions
    }

    public static func persist(
        _ update: CloudTranscriptUpdate,
        in database: Database
    ) throws -> [Message] {
        let canonicalSessionID = CloudCanonicalID.session(
            accountID: update.accountID,
            remoteSessionID: update.sessionID
        )
        guard let sessionMetadata = try CloudSessionMetadata
            .find(canonicalSessionID)
            .fetchOne(database),
              sessionMetadata.accountID == update.accountID,
              sessionMetadata.cloudSessionID == update.sessionID else {
            throw CloudChatPersistenceError.transcriptOwnershipMismatch
        }

        let isCompleteUpdate = update.kind == .complete
        if isCompleteUpdate {
            // A complete response is authoritative. Removing the old
            // projection once makes deleted and newly unsupported events
            // disappear without a metadata SELECT for every incoming event.
            let storedMetadata = try CloudMessageMetadata
                .where { $0.canonicalSessionID.eq(canonicalSessionID) }
                .fetchAll(database)
            try removeMessages(storedMetadata, from: database)
        }

        // Unique complete events can be projected first and written in two
        // multi-row statements. Duplicate IDs need the event-by-event path:
        // if their final occurrence projects no message, it must remove an
        // earlier occurrence from the same response.
        let shouldBatchCompleteUpdate =
            isCompleteUpdate
            && Set(update.messages.map(\.id)).count == update.messages.count
        let persistedMessages = if shouldBatchCompleteUpdate {
            try persistCompleteMessages(
                update.messages,
                accountID: update.accountID,
                remoteSessionID: update.sessionID,
                canonicalSessionID: canonicalSessionID,
                in: database
            )
        } else {
            try persistMessagesIndividually(
                update.messages,
                accountID: update.accountID,
                remoteSessionID: update.sessionID,
                canonicalSessionID: canonicalSessionID,
                isCompleteUpdate: isCompleteUpdate,
                in: database
            )
        }
        try acknowledgeObservedDeliveries(
            update.messages,
            accountID: update.accountID,
            remoteSessionID: update.sessionID,
            canonicalSessionID: canonicalSessionID,
            in: database
        )

        var updatedMetadata = sessionMetadata
        updatedMetadata.transcriptCursor = update.rawCursor
        updatedMetadata.hasCompleteTranscript =
            update.kind == .complete || sessionMetadata.hasCompleteTranscript
        updatedMetadata.transcriptProjectionVersion =
            CloudTranscriptAdapter.projectionVersion
        if update.kind == .complete {
            updatedMetadata.lastFullTranscriptRefreshAt =
                update.completedAt ?? Date()
        }
        try CloudSessionMetadata
            .upsert { updatedMetadata }
            .execute(database)
        return persistedMessages
    }

    public static func cachedTranscript(
        for canonicalSessionID: Session.ID,
        in database: Database
    ) throws -> CloudCachedTranscript {
        guard let metadata = try CloudSessionMetadata
            .find(canonicalSessionID)
            .fetchOne(database),
              canonicalSessionID == CloudCanonicalID.session(
                accountID: metadata.accountID,
                remoteSessionID: metadata.cloudSessionID
              ) else {
            throw CloudChatPersistenceError.transcriptOwnershipMismatch
        }
        let messages = try CloudMessageMetadata
            .messages(sessionID: canonicalSessionID)
            .fetchAll(database)
        let checkpoint: CloudTranscriptCheckpoint? =
            if metadata.hasCompleteTranscript,
               metadata.transcriptProjectionVersion
                == CloudTranscriptAdapter.projectionVersion,
               let lastFullTranscriptRefreshAt =
                metadata.lastFullTranscriptRefreshAt {
                CloudTranscriptCheckpoint(
                    accountID: metadata.accountID,
                    remoteSessionID: metadata.cloudSessionID,
                    rawCursor: metadata.transcriptCursor,
                    lastFullTranscriptRefreshAt: lastFullTranscriptRefreshAt
                )
            } else {
                nil
            }
        return CloudCachedTranscript(
            remoteSessionID: metadata.cloudSessionID,
            messages: messages,
            checkpoint: checkpoint
        )
    }

    public static func reconcileDeliveryAttempts(
        for canonicalSessionID: Session.ID,
        in database: Database
    ) throws {
        guard let metadata = try CloudSessionMetadata
            .find(canonicalSessionID)
            .fetchOne(database) else {
            return
        }
        try acknowledgePersistedDeliveries(
            accountID: metadata.accountID,
            remoteSessionID: metadata.cloudSessionID,
            canonicalSessionID: canonicalSessionID,
            in: database
        )
    }

    public static func remoteSessionID(
        for canonicalSessionID: Session.ID,
        in database: Database
    ) throws -> String? {
        try CloudSessionMetadata
            .find(canonicalSessionID)
            .fetchOne(database)?
            .cloudSessionID
    }

    public static func clearCachedRows(
        in database: Database,
        keepingAccountID: String? = nil
    ) throws {
        let metadata = if let keepingAccountID {
            try CloudSessionMetadata
                .where { $0.accountID.neq(keepingAccountID) }
                .fetchAll(database)
        } else {
            try CloudSessionMetadata.all.fetchAll(database)
        }
        try CloudOwnershipCleanup.perform(
            scope: .sessions(Set(metadata.map(\.canonicalSessionID))),
            reason: keepingAccountID == nil
                ? .credentialRemoval
                : .authoritativeSnapshot,
            in: database
        )
    }

    private static func canonicalSession(
        _ cloudSession: CloudSession,
        canonicalID: Session.ID,
        workspaceID: Workspace.ID,
        status: CloudSessionStatusResponse?,
        existing: Session?
    ) -> Session {
        let model = cloudSession.model
            ?? cloudSession.resolvedModel
            ?? existing?.model.rawValue
            ?? ""
        let agent = cloudSession.agent
            ?? Session.Model(rawValue: model).agentType?.rawValue
            ?? existing?.agentType.rawValue
            ?? "unknown"
        let updatedAt = status?.updatedAt.ISO8601Format()
            ?? existing?.updatedAt
            ?? Date.distantPast.ISO8601Format()
        let createdAt = existing?.createdAt ?? updatedAt
        let agentType = Session.AgentType(rawValue: agent)
        let effort = cloudSession.effort
            .map(Session.ReasoningEffort.init(rawValue:))
            ?? (
                existing?.agentType == agentType
                    ? existing?.reasoningEffort
                    : nil
            )

        return Session(
            id: canonicalID,
            workspaceID: workspaceID,
            title: cloudSession.name,
            agentType: agentType,
            isHidden: cloudSession.archivedAt != nil
                || existing?.isHidden == true,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastUserMessageAt: existing?.lastUserMessageAt,
            status: Session.Status(
                rawValue: status?.status.rawValue ?? "unknown"
            ),
            model: Session.Model(rawValue: model),
            unreadCount: existing?.unreadCount ?? 0,
            freshlyCompacted: existing?.freshlyCompacted ?? 0,
            contextTokenCount: existing?.contextTokenCount ?? 0,
            codexThinkingLevel: agentType == .codex
                ? effort
                : nil,
            isFastModeEnabled: cloudSession.fastMode
                ?? existing?.isFastModeEnabled,
            claudeEffortLevel: agentType == .claude
                ? effort
                : nil,
            queuePausedAt: existing?.queuePausedAt
        )
    }

    private static func removeSessions(
        _ metadata: [CloudSessionMetadata],
        from database: Database
    ) throws {
        for item in metadata {
            try Session.find(item.canonicalSessionID).delete().execute(database)
        }
    }

    private static func reconcileStaleSessions(
        _ metadata: [CloudSessionMetadata],
        accountID: String,
        in database: Database
    ) throws {
        try CloudOwnershipCleanup.perform(
            scope: .sessions(Set(metadata.map(\.canonicalSessionID))),
            reason: .authoritativeSnapshot,
            in: database
        )
    }

    private static func pendingAttempts(
        accountID: String,
        canonicalSessionID: Session.ID,
        in database: Database
    ) throws -> [CloudPendingMutation] {
        try CloudPendingMutation
            .where {
                $0.accountID.eq(accountID)
                    && $0.canonicalSessionID.eq(canonicalSessionID)
                    && $0.state.neq(
                        CloudPendingMutation.State.acknowledged.rawValue
                    )
            }
            .fetchAll(database)
    }

    private static func removeMessages(
        _ metadata: [CloudMessageMetadata],
        from database: Database
    ) throws {
        // An IN clause binds one variable per ID. Use the connection's actual
        // limit so normal transcripts delete in one statement while an
        // unusually large cache still cannot produce invalid SQL.
        try forEachBatch(
            metadata.map(\.canonicalMessageID),
            size: database.maximumStatementArgumentCount
        ) { messageIDs in
            try Message
                .where { $0.id.in(messageIDs) }
                .delete()
                .execute(database)
        }
    }

    private static func persistCompleteMessages(
        _ events: [CloudTranscriptMessage],
        accountID: String,
        remoteSessionID: String,
        canonicalSessionID: Session.ID,
        in database: Database
    ) throws -> [Message] {
        // Projection is pure Swift work. Finishing it before touching SQLite
        // lets each table use one multi-row upsert for ordinary transcripts,
        // instead of one statement per projected message and metadata row.
        var messages: [Message] = []
        var metadata: [CloudMessageMetadata] = []
        for event in events {
            let parts = CloudTranscriptAdapter.adapt(
                event,
                accountID: accountID,
                remoteSessionID: remoteSessionID,
                canonicalSessionID: canonicalSessionID
            )
            for part in parts {
                messages.append(part.message)
                metadata.append(
                    CloudMessageMetadata(
                        canonicalMessageID: part.message.id,
                        cloudEventID: event.id,
                        canonicalSessionID: canonicalSessionID,
                        sessionIndex: event.sessionIndex,
                        adapterPartOrder: part.order,
                        accountID: accountID
                    )
                )
            }
        }

        let maximumArgumentCount = database.maximumStatementArgumentCount
        let messageBatchSize = maximumRowsPerStatement(
            maximumArgumentCount: maximumArgumentCount,
            argumentsPerRow: messageArgumentsPerRow
        )
        let metadataBatchSize = maximumRowsPerStatement(
            maximumArgumentCount: maximumArgumentCount,
            argumentsPerRow: messageMetadataArgumentsPerRow
        )
        try forEachBatch(messages, size: messageBatchSize) { batch in
            try Message.upsert { batch }.execute(database)
        }
        try forEachBatch(metadata, size: metadataBatchSize) { batch in
            try CloudMessageMetadata.upsert { batch }.execute(database)
        }
        return messages
    }

    static func maximumRowsPerStatement(
        maximumArgumentCount: Int,
        argumentsPerRow: Int
    ) -> Int {
        // SQLite rejects a statement with more bound variables than the
        // connection allows. Dividing by the record's column count gives the
        // largest safe multi-row statement and avoids an arbitrary row cap.
        max(1, maximumArgumentCount / argumentsPerRow)
    }

    private static func persistMessagesIndividually(
        _ events: [CloudTranscriptMessage],
        accountID: String,
        remoteSessionID: String,
        canonicalSessionID: Session.ID,
        isCompleteUpdate: Bool,
        in database: Database
    ) throws -> [Message] {
        var messages: [Message] = []
        var processedCompleteEventIDs: Set<String> = []
        for event in events {
            // Incremental responses contain only changed events, so their old
            // projection must be found and removed individually. Complete
            // responses already cleared the table, except duplicate event IDs
            // whose later occurrence must replace the earlier one.
            let shouldRemovePreviousParts =
                !isCompleteUpdate
                || !processedCompleteEventIDs.insert(event.id).inserted
            if shouldRemovePreviousParts {
                let previousParts = try CloudMessageMetadata
                    .where {
                        $0.canonicalSessionID.eq(canonicalSessionID)
                            && $0.cloudEventID.eq(event.id)
                    }
                    .fetchAll(database)
                try removeMessages(previousParts, from: database)
            }

            let parts = CloudTranscriptAdapter.adapt(
                event,
                accountID: accountID,
                remoteSessionID: remoteSessionID,
                canonicalSessionID: canonicalSessionID
            )
            for part in parts {
                try Message.upsert { part.message }.execute(database)
                try CloudMessageMetadata
                    .upsert {
                        CloudMessageMetadata(
                            canonicalMessageID: part.message.id,
                            cloudEventID: event.id,
                            canonicalSessionID: canonicalSessionID,
                            sessionIndex: event.sessionIndex,
                            adapterPartOrder: part.order,
                            accountID: accountID
                        )
                    }
                    .execute(database)
                messages.append(part.message)
            }
        }
        return messages
    }

    private static func forEachBatch<Element>(
        _ elements: [Element],
        size: Int,
        operation: ([Element]) throws -> Void
    ) rethrows {
        // Callers choose size from SQLite's variable limit. Almost every real
        // transcript therefore executes one iteration; this loop only exists
        // so a transcript larger than one legal SQL statement remains valid.
        for startIndex in stride(
            from: elements.startIndex,
            to: elements.endIndex,
            by: size
        ) {
            let endIndex = min(startIndex + size, elements.endIndex)
            try operation(Array(elements[startIndex..<endIndex]))
        }
    }

    private static func acknowledgeObservedDeliveries(
        _ events: [CloudTranscriptMessage],
        accountID: String,
        remoteSessionID: String,
        canonicalSessionID: Session.ID,
        in database: Database
    ) throws {
        let observedEvents = events.compactMap { event -> (
            remoteMessageID: String,
            canonicalMessageID: Message.ID?,
            canonicalTurnID: String?
        )? in
            guard let remoteMessageID = observedRemoteMessageID(for: event) else {
                return nil
            }
            let userMessage = CloudTranscriptAdapter
                .adapt(
                    event,
                    accountID: accountID,
                    remoteSessionID: remoteSessionID,
                    canonicalSessionID: canonicalSessionID
                )
                .first { $0.message.role == .user }?
                .message
            return (
                remoteMessageID.lowercased(),
                userMessage?.id,
                userMessage?.turnID
            )
        }
        guard !observedEvents.isEmpty else {
            return
        }
        let attempts = try MessageDeliveryAttempt
            .where {
                $0.accountID.eq(accountID)
                    && $0.canonicalSessionID.eq(canonicalSessionID)
                    && $0.route.eq(MessageDeliveryAttempt.Route.cloud.rawValue)
                    && $0.state.neq(
                        MessageDeliveryAttempt.State.acknowledged.rawValue
                    )
            }
            .fetchAll(database)
        for attempt in attempts {
            let attemptID = attempt.attemptID.uuidString.lowercased()
            guard let observed = observedEvents.first(where: {
                $0.remoteMessageID == attemptID
            }) else {
                continue
            }
            _ = try MessageDeliveryAttempt.acknowledge(
                attemptID: attempt.attemptID,
                canonicalMessageID: observed.canonicalMessageID,
                canonicalTurnID: observed.canonicalTurnID,
                at: Date(),
                in: database
            )
        }
    }

    private static func observedRemoteMessageID(
        for event: CloudTranscriptMessage
    ) -> String? {
        guard case let .object(content) = event.content,
              case .string("userMessage") = content["type"] else {
            return nil
        }
        if case let .string(messageID) = content["id"] {
            return messageID
        } else if case let .string(turnID) = content["turnId"] {
            return turnID
        } else {
            return event.id
        }
    }

    private static func acknowledgePersistedDeliveries(
        accountID: String,
        remoteSessionID: String,
        canonicalSessionID: Session.ID,
        in database: Database
    ) throws {
        let messages = try CloudMessageMetadata
            .messages(sessionID: canonicalSessionID)
            .fetchAll(database)
            .filter { $0.role == .user }
        let metadata = try CloudMessageMetadata
            .where { $0.canonicalSessionID.eq(canonicalSessionID) }
            .fetchAll(database)
        let messagesByID = Dictionary(
            uniqueKeysWithValues: messages.map { ($0.id, $0) }
        )
        let attempts = try MessageDeliveryAttempt
            .where {
                $0.accountID.eq(accountID)
                    && $0.canonicalSessionID.eq(canonicalSessionID)
                    && $0.route.eq(MessageDeliveryAttempt.Route.cloud.rawValue)
                    && $0.state.neq(
                        MessageDeliveryAttempt.State.acknowledged.rawValue
                    )
            }
            .fetchAll(database)
        for attempt in attempts {
            let remoteMessageID = attempt.attemptID.uuidString.lowercased()
            let canonicalRemoteTurnID = CloudCanonicalID.turn(
                accountID: accountID,
                remoteSessionID: remoteSessionID,
                remoteTurnID: remoteMessageID
            )
            let message = messages.first {
                $0.sdkMessageID?.lowercased() == remoteMessageID
                    || $0.turnID == canonicalRemoteTurnID
            } ?? metadata.first {
                $0.cloudEventID.lowercased() == remoteMessageID
            }.flatMap { messagesByID[$0.canonicalMessageID] }
            guard let message else {
                continue
            }
            _ = try MessageDeliveryAttempt.acknowledge(
                attemptID: attempt.attemptID,
                canonicalMessageID: message.id,
                canonicalTurnID: message.turnID,
                at: Date(),
                in: database
            )
        }
    }
}
