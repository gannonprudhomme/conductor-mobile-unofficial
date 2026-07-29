//
//  ChatMessageCache.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/29/26.
//

import SharedConductorData
import SQLiteData

public enum ChatMessageCache {
    public static func messages(
        sessionID: Session.ID,
        isCloudHosted: Bool,
        in database: Database
    ) throws -> [Message] {
        if isCloudHosted {
            return try CloudMessageMetadata
                .messages(sessionID: sessionID)
                .fetchAll(database)
        }
        return try localMessages(sessionID: sessionID)
            .fetchAll(database)
    }

    public static func localMessages(
        sessionID: Session.ID
    ) -> some SelectStatement<(), Message, ()> {
        Message
            .where {
                $0.sessionID.eq(sessionID)
                    && ($0.sentAt.isNot(nil) || $0.queueOrder.is(nil))
            }
            .order {
                (
                    $0.sentAt.asc(nulls: .last),
                    $0.createdAt,
                    $0.id
                )
            }
    }
}
