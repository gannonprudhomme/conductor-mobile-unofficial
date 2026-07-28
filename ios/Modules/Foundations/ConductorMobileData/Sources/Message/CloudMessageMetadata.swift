//
//  CloudMessageMetadata.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/27/26.
//

import SharedConductorData
import SQLiteData

@Table("cloud_message_metadata")
public struct CloudMessageMetadata: Equatable, Identifiable, Sendable {
    @Column("message_id", primaryKey: true)
    public let messageID: Message.ID
    @Column("session_id")
    public var sessionID: Session.ID
    @Column("account_id")
    public var accountID: String
    @Column("source_message_id")
    public var sourceMessageID: String
    @Column("last_seen_generation")
    public var lastSeenGeneration: String

    public init(
        messageID: Message.ID,
        sessionID: Session.ID,
        accountID: String,
        sourceMessageID: String,
        lastSeenGeneration: String
    ) {
        self.messageID = messageID
        self.sessionID = sessionID
        self.accountID = accountID
        self.sourceMessageID = sourceMessageID
        self.lastSeenGeneration = lastSeenGeneration
    }

    public var id: Message.ID { messageID }
}
