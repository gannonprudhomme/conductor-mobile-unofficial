//
//  Session.swift
//  SharedConductorData
//
//  Created by Gannon Prudomme on 7/12/26.
//

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
    public var model: Model
    @Column("fast_mode")
    public var fastMode: Bool?
    @Column("unread_count")
    public var unreadCount: Int
    @Column("freshly_compacted")
    public var freshlyCompacted: Int
    @Column("context_token_count")
    public var contextTokenCount: Int

    public init(
        id: String,
        workspaceID: String,
        title: String,
        agentType: AgentType,
        isHidden: Bool,
        createdAt: String,
        updatedAt: String,
        lastUserMessageAt: String?,
        status: Status,
        model: Model,
        unreadCount: Int,
        freshlyCompacted: Int,
        contextTokenCount: Int,
        fastMode: Bool? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.title = title
        self.agentType = agentType
        self.isHidden = isHidden
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUserMessageAt = lastUserMessageAt
        self.status = status
        self.model = model
        self.fastMode = fastMode
        self.unreadCount = unreadCount
        self.freshlyCompacted = freshlyCompacted
        self.contextTokenCount = contextTokenCount
    }
}

extension Session {
    public struct AgentType: Codable, Hashable, QueryBindable, QueryDecodable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let claude = Self(rawValue: "claude")
        public static let codex = Self(rawValue: "codex")

    }

    public struct Model: Codable, Hashable, QueryBindable, QueryDecodable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let fable5 = Self(rawValue: "fable-5")
        public static let opus = Self(rawValue: "opus")
        public static let opus_1M = Self(rawValue: "opus-1m")
        public static let opus4_8_1M = Self(rawValue: "opus-4-8-1m")
        public static let opus4_7_1M = Self(rawValue: "opus-4-7-1m")
        public static let opus4_6_1M = Self(rawValue: "opus-4-6-1m")
        public static let sonnet5_1M = Self(rawValue: "sonnet-5-1m")
        public static let sonnet4_6_1M = Self(rawValue: "sonnet-4-6-1m")
        public static let sonnet4_6 = Self(rawValue: "sonnet")
        public static let haiku4_5 = Self(rawValue: "haiku")
        public static let gpt5_6Sol = Self(rawValue: "gpt-5.6-sol")
        public static let gpt5_6Terra = Self(rawValue: "gpt-5.6-terra")
        public static let gpt5_6Luna = Self(rawValue: "gpt-5.6-luna")
        public static let gpt5_5 = Self(rawValue: "gpt-5.5")
        public static let gpt5_4 = Self(rawValue: "gpt-5.4")
        public static let gpt5_3Codex = Self(rawValue: "gpt-5.3-codex")
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

    public struct AgentOptions: Codable, Equatable, Sendable {
        public var fastMode: Bool

        public init(fastMode: Bool) {
            self.fastMode = fastMode
        }

        private enum CodingKeys: String, CodingKey {
            case fastMode = "fast_mode"
        }
    }
}

extension Session {
    public var agentOptions: AgentOptions {
        AgentOptions(fastMode: fastMode ?? false)
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
        case fastMode = "fast_mode"
        case unreadCount = "unread_count"
        case freshlyCompacted = "freshly_compacted"
        case contextTokenCount = "context_token_count"
    }
}
