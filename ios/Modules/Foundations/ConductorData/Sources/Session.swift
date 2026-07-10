import Foundation
import SQLiteData

@Table("sessions")
public struct Session: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    @Column("workspace_id")
    public var workspaceID: String
    public var title: String
    @Column("agent_type")
    public var agentType: AgentType
    @Column("is_hidden")
    public var isHidden: Bool
    @Column("created_at")
    public var createdAt: String
    @Column("updated_at")
    public var updatedAt: String
    @Column("last_user_message_at")
    public var lastUserMessageAt: String?
    public var status: Status
    public var model: String
    @Column("unread_count")
    public var unreadCount: Int
    @Column("freshly_compacted")
    public var freshlyCompacted: Int
    @Column("context_token_count")
    public var contextTokenCount: Int
}

extension Session {
    public struct AgentType: Codable, Hashable, QueryBindable, QueryDecodable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let claude = Self(rawValue: "claude")
        public static let codex = Self(rawValue: "codex")

        public var displayName: String {
            switch self {
            case .codex:
                "Codex"
            case .claude:
                "Claude"
            default:
                rawValue
            }
        }
    }

    public struct Status: Codable, Hashable, QueryBindable, QueryDecodable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let idle = Self(rawValue: "idle")
        public static let error = Self(rawValue: "error")
        public static let working = Self(rawValue: "working")
    }
}

extension Session {
    public var displayTitle: String {
        title.isEmpty ? "Untitled Session" : title
    }

    public var debugSubtitle: String {
        [status.rawValue, model, agentType.rawValue]
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }

    public var updatedDate: Date? {
        Date.conductorDate(from: updatedAt)
    }
}

extension Session {
    enum CodingKeys: String, CodingKey {
        case id
        case workspaceID = "workspace_id"
        case title
        case agentType = "agent_type"
        case isHidden = "is_hidden"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastUserMessageAt = "last_user_message_at"
        case status
        case model
        case unreadCount = "unread_count"
        case freshlyCompacted = "freshly_compacted"
        case contextTokenCount = "context_token_count"
    }
}
