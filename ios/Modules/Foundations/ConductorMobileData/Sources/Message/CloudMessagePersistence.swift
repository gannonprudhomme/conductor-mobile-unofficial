//
//  CloudMessagePersistence.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/27/26.
//

import ConductorCloud
import Foundation
import SharedConductorData
import SQLiteData

public enum CloudMessagePersistence {
    @discardableResult
    public static func persist(
        _ snapshot: CloudTranscriptSnapshot,
        in database: Database
    ) throws -> [Message] {
        let generation = UUID().uuidString
        let adaptedMessages = CloudTranscriptAdapter.adapt(snapshot.messages)
        let messages = adaptedMessages.map(\.message)
        let messageIDs = Set(messages.map(\.id))

        if !messages.isEmpty {
            try Message.upsert { messages }.execute(database)
        }
        let metadata = adaptedMessages.map {
            CloudMessageMetadata(
                messageID: $0.message.id,
                sessionID: snapshot.sessionID,
                accountID: snapshot.accountID,
                sourceMessageID: $0.sourceMessageID,
                lastSeenGeneration: generation
            )
        }
        if !metadata.isEmpty {
            try CloudMessageMetadata.upsert { metadata }.execute(database)
        }

        let staleMetadata: [CloudMessageMetadata]
        if snapshot.isFullSnapshot {
            staleMetadata = try CloudMessageMetadata
                .where {
                    $0.sessionID.eq(snapshot.sessionID)
                        && (
                            $0.accountID.neq(snapshot.accountID)
                                || $0.lastSeenGeneration.neq(generation)
                        )
                }
                .fetchAll(database)
        } else {
            let sourceMessageIDs = Set(
                snapshot.messages.map(\.id)
            )
            let replacedMetadata = try CloudMessageMetadata
                .where { $0.sessionID.eq(snapshot.sessionID) }
                .fetchAll(database)
            staleMetadata = replacedMetadata.filter {
                sourceMessageIDs.contains($0.sourceMessageID)
                    && !messageIDs.contains($0.messageID)
            }
        }
        try removeOwnedMessages(staleMetadata, from: database)
        try updateSessionStatus(snapshot.status, in: database)
        return messages
    }

    public static func removeOwnedMessages(
        _ metadata: [CloudMessageMetadata],
        from database: Database
    ) throws {
        for item in metadata {
            try CloudMessageMetadata
                .find(item.messageID)
                .delete()
                .execute(database)
            try Message.find(item.messageID).delete().execute(database)
        }
    }

    private static func updateSessionStatus(
        _ status: CloudSessionStatusResponse,
        in database: Database
    ) throws {
        try Session
            .find(status.sessionID)
            .update {
                $0.status = #bind(
                    Session.Status(rawValue: status.status.rawValue)
                )
                $0.updatedAt = #bind(status.updatedAt.ISO8601Format())
            }
            .execute(database)
    }
}
