//
//  Message.swift
//  SharedConductorData
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Foundation
import SQLiteData

@Table("session_messages")
public struct Message: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    @Column("session_id")
    public var sessionID: String?
    public var role: Role?
    public var content: String?
    @Column("created_at", as: Date.ConductorDatabaseRepresentation.self)
    public var createdAt: Date
    @Column("sent_at", as: Date.ConductorDatabaseRepresentation?.self)
    public var sentAt: Date?
    @Column("full_message")
    public var fullMessage: String?
    @Column("cancelled_at")
    public var cancelledAt: String?
    public var model: String?
    @Column("sdk_message_id")
    public var sdkMessageID: String?
    @Column("last_assistant_message_id")
    public var lastAssistantMessageID: String?
    @Column("turn_id")
    public var turnID: String?
    @Column("is_resumable_message")
    public var isResumableMessage: Int?
    @Column("queue_order")
    public var queueOrder: Int?
    @Column("sender_id")
    public var senderID: String?

    public init(
        id: String,
        sessionID: String? = nil,
        role: Role? = nil,
        content: String? = nil,
        createdAt: Date,
        sentAt: Date? = nil,
        fullMessage: String? = nil,
        cancelledAt: String? = nil,
        model: String? = nil,
        sdkMessageID: String? = nil,
        lastAssistantMessageID: String? = nil,
        turnID: String? = nil,
        isResumableMessage: Int? = nil,
        queueOrder: Int? = nil,
        senderID: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.sentAt = sentAt
        self.fullMessage = fullMessage
        self.cancelledAt = cancelledAt
        self.model = model
        self.sdkMessageID = sdkMessageID
        self.lastAssistantMessageID = lastAssistantMessageID
        self.turnID = turnID
        self.isResumableMessage = isResumableMessage
        self.queueOrder = queueOrder
        self.senderID = senderID
    }
}

extension Message {
    /// Whether Conductor currently treats this row as a mutable queued message.
    ///
    /// The desktop server uses this exact persisted-state rule to separate completed history from
    /// the queue. The mobile cache uses the same rule when reconciling complete queue snapshots.
    /// Rows that satisfy only one condition remain completed history.
    public var isQueued: Bool {
        sentAt == nil && queueOrder != nil
    }
}

extension Message {
    public struct Role: Codable, Hashable, QueryBindable, QueryDecodable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let user = Self(rawValue: "user")
        public static let assistant = Self(rawValue: "assistant")
    }
}

extension Message {
    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case role
        case content
        case createdAt = "created_at"
        case sentAt = "sent_at"
        case fullMessage = "full_message"
        case cancelledAt = "cancelled_at"
        case model
        case sdkMessageID = "sdk_message_id"
        case lastAssistantMessageID = "last_assistant_message_id"
        case turnID = "turn_id"
        case isResumableMessage = "is_resumable_message"
        case queueOrder = "queue_order"
        case senderID = "sender_id"
    }
}
