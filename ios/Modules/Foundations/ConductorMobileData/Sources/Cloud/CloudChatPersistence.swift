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

        if update.kind == .complete {
            let eventIDs = Set(update.messages.map(\.id))
            let storedMetadata = try CloudMessageMetadata
                .where { $0.canonicalSessionID.eq(canonicalSessionID) }
                .fetchAll(database)
            let staleMetadata = storedMetadata.filter {
                !eventIDs.contains($0.cloudEventID)
            }
            try removeMessages(staleMetadata, from: database)
        }

        var persistedMessages: [Message] = []
        for event in update.messages {
            let previousParts = try CloudMessageMetadata
                .where {
                    $0.canonicalSessionID.eq(canonicalSessionID)
                        && $0.cloudEventID.eq(event.id)
                }
                .fetchAll(database)
            try removeMessages(previousParts, from: database)

            let parts = CloudTranscriptAdapter.adapt(
                event,
                accountID: update.accountID,
                remoteSessionID: update.sessionID,
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
                            accountID: update.accountID
                        )
                    }
                    .execute(database)
                persistedMessages.append(part.message)
            }
            try acknowledgeObservedSend(
                eventID: event.id,
                accountID: update.accountID,
                canonicalSessionID: canonicalSessionID,
                in: database
            )
        }

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
        let effort = cloudSession.effort.map(Session.ReasoningEffort.init(rawValue:))
        let agentType = Session.AgentType(rawValue: agent)

        return Session(
            id: canonicalID,
            workspaceID: workspaceID,
            title: cloudSession.name,
            agentType: agentType,
            isHidden: cloudSession.archivedAt != nil,
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
                : existing?.codexThinkingLevel,
            isFastModeEnabled: cloudSession.fastMode,
            claudeEffortLevel: agentType == .claude
                ? effort
                : existing?.claudeEffortLevel,
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
        for item in metadata {
            try Message.find(item.canonicalMessageID).delete().execute(database)
        }
    }

    private static func acknowledgeObservedSend(
        eventID: String,
        accountID: String,
        canonicalSessionID: Session.ID,
        in database: Database
    ) throws {
        let attempts = try CloudPendingMutation
            .where {
                $0.accountID.eq(accountID)
                    && $0.canonicalSessionID.eq(canonicalSessionID)
                    && $0.stableRemoteMessageID.eq(eventID)
            }
            .fetchAll(database)
        for attempt in attempts
        where attempt.mutationOperation == .sendMessage {
            _ = try CloudPendingMutation.compareAndSetState(
                attemptID: attempt.attemptID,
                from: attempt.mutationState,
                to: .acknowledged,
                at: Date(),
                in: database
            )
        }
    }
}
