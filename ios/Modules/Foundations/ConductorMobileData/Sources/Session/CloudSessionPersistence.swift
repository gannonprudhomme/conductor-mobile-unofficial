//
//  CloudSessionPersistence.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/27/26.
//

import ConductorCloud
import Foundation
import SharedConductorData
import SQLiteData

public enum CloudSessionPersistence {
    public static func persist(
        _ snapshot: CloudSessionSnapshot,
        in database: Database
    ) throws {
        let generation = UUID().uuidString
        let existingSessions = try Session
            .where { $0.workspaceID.eq(snapshot.workspace.id) }
            .fetchAll(database)
        let existingByID = Dictionary(
            uniqueKeysWithValues: existingSessions.map { ($0.id, $0) }
        )
        let sessions = snapshot.sessions.map { cloudSession in
            canonicalSession(
                cloudSession,
                workspaceID: snapshot.workspace.id,
                status: snapshot.statuses[cloudSession.id],
                existing: existingByID[cloudSession.id]
            )
        }

        if !sessions.isEmpty {
            try Session.upsert { sessions }.execute(database)
        }
        let metadata = sessions.map {
            CloudSessionMetadata(
                sessionID: $0.id,
                workspaceID: snapshot.workspace.id,
                accountID: snapshot.accountID,
                lastSeenGeneration: generation
            )
        }
        if !metadata.isEmpty {
            try CloudSessionMetadata.upsert { metadata }.execute(database)
        }

        let staleMetadata = try CloudSessionMetadata
            .where {
                $0.workspaceID.eq(snapshot.workspace.id)
                    && (
                        $0.accountID.neq(snapshot.accountID)
                            || $0.lastSeenGeneration.neq(generation)
                    )
            }
            .fetchAll(database)
        try removeOwnedSessions(staleMetadata, from: database)
        try updateActiveSession(
            for: snapshot,
            canonicalSessions: sessions,
            in: database
        )
    }

    public static func removeOwnedSessions(
        _ metadata: [CloudSessionMetadata],
        from database: Database
    ) throws {
        for item in metadata {
            let messageMetadata = try CloudMessageMetadata
                .where { $0.sessionID.eq(item.sessionID) }
                .fetchAll(database)
            try CloudMessagePersistence.removeOwnedMessages(
                messageMetadata,
                from: database
            )
            try CloudSessionMetadata
                .find(item.sessionID)
                .delete()
                .execute(database)
            try Session.find(item.sessionID).delete().execute(database)
        }
    }

    private static func canonicalSession(
        _ cloudSession: CloudSession,
        workspaceID: Workspace.ID,
        status: CloudSessionStatusResponse?,
        existing: Session?
    ) -> Session {
        let model = Session.Model(
            rawValue: cloudSession.model
                ?? cloudSession.resolvedModel
                ?? existing?.model.rawValue
                ?? Session.Model.gpt_5_6_sol.rawValue
        )
        let agentType = model.agentType ?? existing?.agentType ?? .codex
        let updatedAt = status?.updatedAt.ISO8601Format()
            ?? existing?.updatedAt
            ?? Date.now.ISO8601Format()
        let createdAt = existing?.createdAt ?? updatedAt
        let effort = cloudSession.effort.map(Session.ReasoningEffort.init)

        return Session(
            id: cloudSession.id,
            workspaceID: workspaceID,
            title: cloudSession.name,
            agentType: agentType,
            isHidden: cloudSession.archivedAt != nil,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastUserMessageAt: existing?.lastUserMessageAt,
            status: status.map {
                Session.Status(rawValue: $0.status.rawValue)
            } ?? existing?.status ?? .idle,
            model: model,
            unreadCount: existing?.unreadCount ?? 0,
            freshlyCompacted: existing?.freshlyCompacted ?? 0,
            contextTokenCount: existing?.contextTokenCount ?? 0,
            codexThinkingLevel: agentType == .codex
                ? effort ?? existing?.codexThinkingLevel
                : existing?.codexThinkingLevel,
            isFastModeEnabled: cloudSession.fastMode
                ?? existing?.isFastModeEnabled,
            claudeEffortLevel: agentType == .claude
                ? effort ?? existing?.claudeEffortLevel
                : existing?.claudeEffortLevel,
            queuePausedAt: nil
        )
    }

    private static func updateActiveSession(
        for snapshot: CloudSessionSnapshot,
        canonicalSessions: [Session],
        in database: Database
    ) throws {
        let visibleSessions = canonicalSessions.filter { !$0.isHidden }
        let visibleSessionIDs = Set(visibleSessions.map(\.id))
        let existingWorkspace = try Workspace
            .find(snapshot.workspace.id)
            .fetchOne(database)
        let activeSessionID = visibleSessions.first {
            $0.status == .working
        }?.id
            ?? existingWorkspace?.activeSessionID.flatMap {
                visibleSessionIDs.contains($0) ? $0 : nil
            }
            ?? visibleSessions.first?.id

        try Workspace
            .find(snapshot.workspace.id)
            .update { $0.activeSessionID = #bind(activeSessionID) }
            .execute(database)
    }
}
