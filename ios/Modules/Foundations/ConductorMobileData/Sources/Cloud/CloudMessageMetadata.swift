//
//  CloudMessageMetadata.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/28/26.
//

import SharedConductorData
import SQLiteData

@Table("cloud_message_metadata")
public struct CloudMessageMetadata: Equatable, Identifiable, Sendable {
    @Column("canonical_message_id", primaryKey: true)
    public let canonicalMessageID: Message.ID
    @Column("cloud_event_id")
    public var cloudEventID: String
    @Column("canonical_session_id")
    public var canonicalSessionID: Session.ID
    @Column("session_index")
    public var sessionIndex: Double
    @Column("adapter_part_order")
    public var adapterPartOrder: Int
    @Column("account_id")
    public var accountID: String

    public init(
        canonicalMessageID: Message.ID,
        cloudEventID: String,
        canonicalSessionID: Session.ID,
        sessionIndex: Double,
        adapterPartOrder: Int,
        accountID: String
    ) {
        self.canonicalMessageID = canonicalMessageID
        self.cloudEventID = cloudEventID
        self.canonicalSessionID = canonicalSessionID
        self.sessionIndex = sessionIndex
        self.adapterPartOrder = adapterPartOrder
        self.accountID = accountID
    }

    public var id: Message.ID { canonicalMessageID }
}

public extension CloudMessageMetadata {
    static func messages(
        sessionID: Session.ID
    ) -> some SelectStatement<
        Message,
        Message,
        CloudMessageMetadata
    > {
        Message
            .join(Self.all) { message, metadata in
                message.id.eq(metadata.canonicalMessageID)
            }
            .where { _, metadata in
                metadata.canonicalSessionID.eq(sessionID)
            }
            .order { message, metadata in
                (
                    metadata.sessionIndex,
                    metadata.adapterPartOrder,
                    message.id
                )
            }
            .select { message, _ in message }
    }
}
