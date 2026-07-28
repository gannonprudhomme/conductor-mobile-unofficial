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
    public var title: String?
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
    @Column("codex_thinking_level")
    public var codexThinkingLevel: ReasoningEffort?
    @Column("fast_mode")
    public var isFastModeEnabled: Bool?
    @Column("claude_effort_level")
    public var claudeEffortLevel: ReasoningEffort?
    @Column("unread_count")
    public var unreadCount: Int
    @Column("freshly_compacted")
    public var freshlyCompacted: Int
    @Column("context_token_count")
    public var contextTokenCount: Int

    // TODO: I don't think we need this at all? Idek what its for
    @Column("queue_paused_at")
    public var queuePausedAt: String?

    public init(
        id: String,
        workspaceID: String,
        title: String?,
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
        codexThinkingLevel: ReasoningEffort? = nil,
        isFastModeEnabled: Bool? = nil,
        claudeEffortLevel: ReasoningEffort? = nil,
        queuePausedAt: String? = nil
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
        self.codexThinkingLevel = codexThinkingLevel
        self.isFastModeEnabled = isFastModeEnabled
        self.claudeEffortLevel = claudeEffortLevel
        self.unreadCount = unreadCount
        self.freshlyCompacted = freshlyCompacted
        self.contextTokenCount = contextTokenCount
        self.queuePausedAt = queuePausedAt
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

    public struct Model: Codable, Hashable, Identifiable, QueryBindable, QueryDecodable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var id: String { rawValue }

        public static let fable5 = Self(rawValue: "fable-5")
        public static let opus = Self(rawValue: "opus")
        public static let opus_1M = Self(rawValue: "opus-1m")
        public static let opus5 = Self(rawValue: "opus-5")
        public static let opus4_8_1M = Self(rawValue: "opus-4-8-1m")
        public static let opus4_7_1M = Self(rawValue: "opus-4-7-1m")
        public static let opus4_6_1M = Self(rawValue: "opus-4-6-1m")
        public static let sonnet5_1M = Self(rawValue: "sonnet-5-1m")
        public static let sonnet_4_6_1M = Self(rawValue: "sonnet-4-6-1m")
        public static let sonnet_4_6 = Self(rawValue: "sonnet")
        public static let haiku4_5 = Self(rawValue: "haiku")
        public static let gpt_5_6_sol = Self(rawValue: "gpt-5.6-sol")
        public static let gpt_5_6_terra = Self(rawValue: "gpt-5.6-terra")
        public static let gpt_5_6_luna = Self(rawValue: "gpt-5.6-luna")
        public static let gpt5_5 = Self(rawValue: "gpt-5.5")
        public static let gpt5_4 = Self(rawValue: "gpt-5.4")
        public static let gpt5_3Codex = Self(rawValue: "gpt-5.3-codex")

        public static let claudeModels: [Self] = [
            .fable5,
            .opus5,
            .opus4_8_1M,
            .opus4_7_1M,
            .opus4_6_1M,
            .sonnet5_1M,
            .sonnet_4_6_1M,
            .sonnet_4_6,
            .haiku4_5,
        ]

        public static let codexModels: [Self] = [
            .gpt_5_6_sol,
            .gpt_5_6_terra,
            .gpt_5_6_luna,
            .gpt5_5,
            .gpt5_4,
        ]

        public static func models(for agentType: AgentType) -> [Self] {
            switch agentType {
            case .claude:
                claudeModels
            case .codex:
                codexModels
            default:
                []
            }
        }

        public var agentType: AgentType? {
            if Self.claudeModels.contains(self) {
                .claude
            } else if Self.codexModels.contains(self) {
                .codex
            } else {
                nil
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
        public static let ultracode = Self(rawValue: "ultracode")
    }
}

extension Session {
    public var reasoningEffort: ReasoningEffort? {
        agentType == .claude ? claudeEffortLevel : codexThinkingLevel
    }

    public func availableReasoningEfforts(for model: Model) -> [ReasoningEffort] {
        Self.availableReasoningEfforts(
            agentType: model.agentType ?? agentType,
            model: model
        )
    }

    public static func availableReasoningEfforts(
        agentType: AgentType,
        model: Model
    ) -> [ReasoningEffort] {
        switch agentType {
        case .codex:
            model.availableCodexReasoningEfforts
        case .claude:
            model.availableClaudeReasoningEfforts
        default:
            []
        }
    }

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
        case codexThinkingLevel = "codex_thinking_level"
        case isFastModeEnabled = "fast_mode"
        case claudeEffortLevel = "claude_effort_level"
        case unreadCount = "unread_count"
        case freshlyCompacted = "freshly_compacted"
        case contextTokenCount = "context_token_count"
        case queuePausedAt = "queue_paused_at"
    }
}

extension Session.Model {
    public var availableClaudeReasoningEfforts: [Session.ReasoningEffort] {
        switch self {
        case .fable5, .opus5, .opus4_8_1M, .opus4_7_1M, .sonnet5_1M:
            [.low, .medium, .high, .extraHigh, .max, .ultracode]
        case .opus4_6_1M, .sonnet_4_6_1M, .sonnet_4_6:
            [.low, .medium, .high, .max]
        case .opus, .opus_1M:
            [.low, .medium, .high]
        default:
            []
        }
    }

    public var availableCodexReasoningEfforts: [Session.ReasoningEffort] {
        switch self {
        case .gpt_5_6_sol, .gpt_5_6_terra:
            [.none, .low, .medium, .high, .extraHigh, .max, .ultra]
        case .gpt_5_6_luna:
            [.none, .low, .medium, .high, .extraHigh, .max]
        case .gpt5_5, .gpt5_4, .gpt5_3Codex:
            [.none, .low, .medium, .high, .extraHigh]
        default:
            []
        }
    }

    public var defaultReasoningEffort: Session.ReasoningEffort {
        switch self {
        case .gpt_5_6_sol:
            .low
        case .gpt_5_6_terra, .gpt_5_6_luna, .gpt5_5:
            .medium
        default:
            .high
        }
    }
}
