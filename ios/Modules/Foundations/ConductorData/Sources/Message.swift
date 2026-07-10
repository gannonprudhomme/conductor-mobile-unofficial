import SQLiteData

@Table("session_messages")
public struct Message: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    @Column("session_id")
    public var sessionID: String?
    public var role: Role?
    public var content: String?
    @Column("created_at")
    public var createdAt: String
    @Column("sent_at")
    public var sentAt: String?
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
