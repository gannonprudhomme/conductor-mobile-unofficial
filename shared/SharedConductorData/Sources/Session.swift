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
    public var model: String
    @Column("permission_mode")
    public var permissionMode: PermissionMode?
    @Column("codex_thinking_level")
    public var codexThinkingLevel: ReasoningEffort?
    @Column("fast_mode")
    public var fastMode: Bool?
    @Column("agent_personality")
    public var agentPersonality: Personality?
    @Column("claude_effort_level")
    public var claudeEffortLevel: ReasoningEffort?
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
        model: String,
        unreadCount: Int,
        freshlyCompacted: Int,
        contextTokenCount: Int,
        permissionMode: PermissionMode? = nil,
        codexThinkingLevel: ReasoningEffort? = nil,
        fastMode: Bool? = nil,
        agentPersonality: Personality? = nil,
        claudeEffortLevel: ReasoningEffort? = nil
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
        self.permissionMode = permissionMode
        self.codexThinkingLevel = codexThinkingLevel
        self.fastMode = fastMode
        self.agentPersonality = agentPersonality
        self.claudeEffortLevel = claudeEffortLevel
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

    public struct Status: Codable, Hashable, QueryBindable, QueryDecodable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let idle = Self(rawValue: "idle")
        public static let error = Self(rawValue: "error")
        public static let working = Self(rawValue: "working")
    }

    public struct PermissionMode: Codable, Hashable, QueryBindable, QueryDecodable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let `default` = Self(rawValue: "default")
        public static let plan = Self(rawValue: "plan")
        public static let bypassPermissions = Self(rawValue: "bypassPermissions")
    }

    public struct Personality: Codable, Hashable, QueryBindable, QueryDecodable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let none = Self(rawValue: "none")
        public static let pragmatic = Self(rawValue: "pragmatic")
    }

    public struct ReasoningEffort: Codable, Hashable, QueryBindable, QueryDecodable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let none = Self(rawValue: "none")
        public static let low = Self(rawValue: "low")
        public static let medium = Self(rawValue: "medium")
        public static let high = Self(rawValue: "high")
        public static let extraHigh = Self(rawValue: "xhigh")
        public static let max = Self(rawValue: "max")
        public static let ultra = Self(rawValue: "ultra")

        public static let knownValues: [Self] = [
            .none,
            .low,
            .medium,
            .high,
            .extraHigh,
            .max,
            .ultra,
        ]
    }

    public struct AgentOptions: Codable, Equatable, Sendable {
        public var fastMode: Bool
        public var reasoningEffort: ReasoningEffort

        public init(fastMode: Bool, reasoningEffort: ReasoningEffort) {
            self.fastMode = fastMode
            self.reasoningEffort = reasoningEffort
        }

        private enum CodingKeys: String, CodingKey {
            case fastMode = "fast_mode"
            case reasoningEffort = "reasoning_effort"
        }
    }
}

extension Session {
    public var reasoningEffort: ReasoningEffort? {
        switch agentType {
        case .claude:
            claudeEffortLevel
        default:
            codexThinkingLevel
        }
    }

    public var agentOptions: AgentOptions {
        AgentOptions(
            fastMode: fastMode ?? false,
            reasoningEffort: reasoningEffort ?? .high
        )
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
        case permissionMode = "permission_mode"
        case codexThinkingLevel = "codex_thinking_level"
        case fastMode = "fast_mode"
        case agentPersonality = "agent_personality"
        case claudeEffortLevel = "claude_effort_level"
        case unreadCount = "unread_count"
        case freshlyCompacted = "freshly_compacted"
        case contextTokenCount = "context_token_count"
    }
}
