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
            let storedDesktopSession = try Session
                .find(cloudSession.id)
                .fetchOne(database)
            let desktopSession: Session? = if storedDesktopSession?.workspaceID
                == snapshot.workspace.id {
                storedDesktopSession
            } else {
                nil
            }
            let existingMetadata = try CloudSessionMetadata
                .find(canonicalID)
                .fetchOne(database)
            let status = snapshot.statuses[cloudSession.id]
            let session = canonicalSession(
                cloudSession,
                canonicalID: canonicalID,
                workspaceID: snapshot.workspace.id,
                status: status,
                existing: existing,
                desktopSession: desktopSession
            )
            try Session.upsert { session }.execute(database)
            try CloudSessionMetadata
                .upsert {
                    CloudSessionMetadata(
                        canonicalSessionID: canonicalID,
                        cloudSessionID: cloudSession.id,
                        workspaceID: snapshot.workspace.id,
                        accountID: snapshot.accountID,
                        listOrder: listOrder,
                        refreshGeneration: generation,
                        transcriptCursor: existingMetadata?.transcriptCursor,
                        hasCompleteTranscript: existingMetadata?.hasCompleteTranscript
                            ?? false,
                        transcriptProjectionVersion: existingMetadata?
                            .transcriptProjectionVersion
                            ?? 0
                    )
                }
                .execute(database)
            canonicalSessions.append(session)
        }

        let staleMetadata = try CloudSessionMetadata
            .where {
                $0.workspaceID.eq(snapshot.workspace.id)
                    && $0.accountID.eq(snapshot.accountID)
                    && $0.refreshGeneration.neq(generation)
            }
            .fetchAll(database)
        try removeSessions(staleMetadata, from: database)
        return canonicalSessions
    }

    public static func reconcileSessionVisibility(
        from desktopSessions: [Session],
        workspaceID: Workspace.ID,
        in database: Database
    ) throws -> [Session] {
        let workspaceSessions = desktopSessions.filter {
            $0.workspaceID == workspaceID
        }
        try Session.upsert { workspaceSessions }.execute(database)
        let desktopSessionsByID = Dictionary(
            uniqueKeysWithValues: workspaceSessions.map { ($0.id, $0) }
        )
        let metadata = try CloudSessionMetadata
            .where { $0.workspaceID.eq(workspaceID) }
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
        }

        var updatedMetadata = sessionMetadata
        updatedMetadata.transcriptCursor = update.rawCursor
        updatedMetadata.hasCompleteTranscript =
            update.kind == .complete || sessionMetadata.hasCompleteTranscript
        updatedMetadata.transcriptProjectionVersion =
            CloudTranscriptAdapter.projectionVersion
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
                == CloudTranscriptAdapter.projectionVersion {
                CloudTranscriptCheckpoint(
                    accountID: metadata.accountID,
                    remoteSessionID: metadata.cloudSessionID,
                    rawCursor: metadata.transcriptCursor
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
        try removeSessions(metadata, from: database)
    }

    public static func removeCachedRows(
        workspaceID: Workspace.ID,
        accountID: String,
        in database: Database
    ) throws {
        let metadata = try CloudSessionMetadata
            .where {
                $0.workspaceID.eq(workspaceID)
                    && $0.accountID.eq(accountID)
            }
            .fetchAll(database)
        try removeSessions(metadata, from: database)
    }

    private static func canonicalSession(
        _ cloudSession: CloudSession,
        canonicalID: Session.ID,
        workspaceID: Workspace.ID,
        status: CloudSessionStatusResponse?,
        existing: Session?,
        desktopSession: Session?
    ) -> Session {
        let model = cloudSession.model
            ?? cloudSession.resolvedModel
            ?? existing?.model.rawValue
            ?? ""
        let inferredAgent = [cloudSession.model, cloudSession.resolvedModel]
            .compactMap { $0 }
            .compactMap { Session.Model(rawValue: $0).agentType }
            .first
        let agent = cloudSession.agent
            ?? inferredAgent?.rawValue
            ?? existing?.agentType.rawValue
            ?? "unknown"
        let updatedAt = status?.updatedAt.ISO8601Format()
            ?? existing?.updatedAt
            ?? Date.distantPast.ISO8601Format()
        let createdAt = existing?.createdAt ?? updatedAt
        let effort = cloudSession.effort.map(Session.ReasoningEffort.init(rawValue:))
        let agentType = Session.AgentType(rawValue: agent)
        let sessionStatus = status?.status.rawValue
            ?? existing?.status.rawValue
            ?? CloudSessionStatusResponse.Status.unknown.rawValue
        let isHidden = desktopSession?.isHidden
            ?? (cloudSession.archivedAt != nil ? true : existing?.isHidden)
            ?? false

        return Session(
            id: canonicalID,
            workspaceID: workspaceID,
            title: cloudSession.name,
            agentType: agentType,
            isHidden: isHidden,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastUserMessageAt: existing?.lastUserMessageAt,
            status: Session.Status(rawValue: sessionStatus),
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
            let messageMetadata = try CloudMessageMetadata
                .where {
                    $0.canonicalSessionID.eq(item.canonicalSessionID)
                        && $0.accountID.eq(item.accountID)
                }
                .fetchAll(database)
            try removeMessages(messageMetadata, from: database)
            try Session.find(item.canonicalSessionID).delete().execute(database)
        }
    }

    private static func removeMessages(
        _ metadata: [CloudMessageMetadata],
        from database: Database
    ) throws {
        for item in metadata {
            try Message.find(item.canonicalMessageID).delete().execute(database)
        }
    }
}
