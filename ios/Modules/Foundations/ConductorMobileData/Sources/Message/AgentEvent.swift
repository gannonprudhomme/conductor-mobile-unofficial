//
//  AgentEvent.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/10/26.
//

import Foundation

/// A normalized agent protocol event stored in ``Message/content`` for assistant-role rows.
///
/// Conductor stores Claude and Codex output in this shared envelope before the mobile companion
/// relays each message unchanged. Some system subtypes remain specific to one agent runtime.
public enum AgentEvent: Decodable, Equatable {
    case assistant(AssistantEvent)
    case user(UserEvent)
    case system(SystemEvent)
    /// The turn finished
    case result(ResultEvent)
    /// Failure or retry status
    case error(ErrorEvent)
    case unknown([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(EventType.self, forKey: .type)

        switch type {
        case .assistant:
            self = .assistant(try AssistantEvent(from: decoder))
        case .user:
            self = .user(try UserEvent(from: decoder))
        case .system:
            self = .system(try SystemEvent(from: decoder))
        case .result:
            self = .result(try ResultEvent(from: decoder))
        case .error:
            self = .error(try ErrorEvent(from: decoder))
        default:
            self = .unknown(try [String: JSONValue].init(from: decoder))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public struct EventType: Codable, Hashable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let assistant = Self(rawValue: "assistant")
        public static let user = Self(rawValue: "user")
        public static let system = Self(rawValue: "system")
        public static let result = Self(rawValue: "result")
        public static let error = Self(rawValue: "error")
    }

    public struct AssistantEvent: Decodable, Hashable, Sendable {
        // public let type: EventType
        // public let sessionID: String?
        public let message: AssistantMessage

        /// `Message.content(parsed).message`
        public struct AssistantMessage: Decodable, Hashable, Sendable {
            // public let role: Role // Doubt we need this, it's the same thing as the `type`
            public let content: [AssistantMessageContent]

            public enum AssistantMessageContent: Decodable, Hashable, Sendable {
                case text(TextBlock)
                case thinking(ThinkingBlock)
                case toolUse(ToolUseBlock)
                // TODO: This makes me wonder if we should be doing the struct approach? but idk
                case unknown([String: JSONValue])

                public init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: AgentEvent.AssistantEvent.AssistantMessage.AssistantMessageContent.CodingKeys.self)
                    let type = try container.decode(AssistantMessageContentType.self, forKey: .type)

                    switch type {
                    case .text:
                        self = .text(try TextBlock(from: decoder))
                    case .thinking:
                        self = .thinking(try ThinkingBlock(from: decoder))
                    case .toolUse:
                        self = .toolUse(try ToolUseBlock(from: decoder))
                    default:
                        self = .unknown(try [String: JSONValue].init(from: decoder))
                    }
                }

                public struct TextBlock: Codable, Hashable, Sendable {
                    // public let type: AssistantMessageContentType
                    public let text: String
                }

                public struct ThinkingBlock: Codable, Hashable, Sendable {
                    // public let type: AssistantMessageContentType
                    public let thinking: String
                }

                public struct ToolUseBlock: Codable, Hashable, Sendable/*, Identifiable*/ {
                    // public let type: AssistantMessageContentType

                    /// `id` is important! It is used to match up with a `user` (aka environment) `ToolResultBlock.toolUseID`
                    /// Aka to match usage of a tool -> result of the tool
                    public let id: String
                    public let name: String
                    public let input: [String: JSONValue]
                }

                private struct AssistantMessageContentType: Codable, Hashable, RawRepresentable {
                    let rawValue: String

                    static let text = Self(rawValue: "text")
                    static let thinking = Self(rawValue: "thinking")
                    static let toolUse = Self(rawValue: "tool_use")
                }

                private enum CodingKeys: String, CodingKey {
                    case type
                }

            }
        }
    }

    public struct UserEvent: Decodable, Hashable, Sendable {
        // public let type: EventType // Don't need it
        public let sessionID: String?
        public let message: UserMessage

        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case message
        }

        public struct UserMessage: Decodable, Hashable, Sendable {
            // public let role: Role
            public let content: [UserMessageContent]

            public enum UserMessageContent: Decodable, Hashable, Sendable {
                case toolResult(ToolResultBlock)
                case unknown([String: JSONValue])

                public init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: AgentEvent.UserEvent.UserMessage.UserMessageContent.CodingKeys.self)
                    let type = try container.decode(UserMessageContentType.self, forKey: .type)

                    switch type {
                    case .toolResult:
                        self = .toolResult(try ToolResultBlock(from: decoder))
                    default:
                        self = .unknown(try [String: JSONValue](from: decoder))
                    }
                }

                public struct ToolResultBlock: Codable, Hashable, Sendable {
                    // public let type: UserMessageContentType
                    public let toolUseID: String
                    public let content: String
                    public let isError: Bool

                    private enum CodingKeys: String, CodingKey {
                        // case type
                        case toolUseID = "tool_use_id"
                        case content
                        case isError = "is_error"
                    }
                }

                private struct UserMessageContentType: RawRepresentable, Codable, Hashable {
                    let rawValue: String

                    static let toolResult = Self(rawValue: "tool_result")
                }

                private enum CodingKeys: String, CodingKey {
                    case type
                }
            }
        }
    }

    public struct SystemEvent: Decodable, Hashable, Sendable {
        public let subtype: Subtype?
        public let state: State?

        public struct Subtype: Codable, Hashable, RawRepresentable, Sendable {
            public var rawValue: String

            public init(rawValue: String) {
                self.rawValue = rawValue
            }

            /// The agent session initialized with its model, tools, skills, and MCP configuration.
            public static let initialization = Self(rawValue: "init")
            /// Runtime status changed, such as beginning compaction or changing permission mode.
            public static let status = Self(rawValue: "status")
            /// Compaction finished and the preceding context was replaced by a summary.
            public static let compactBoundary = Self(rawValue: "compact_boundary")
            /// Claude reported an updated estimate of tokens used by its current thinking block.
            public static let thinkingTokens = Self(rawValue: "thinking_tokens")
            /// Claude started a local agent or shell task.
            public static let taskStarted = Self(rawValue: "task_started")
            /// A Claude subagent reported its latest tool and token usage while running.
            public static let taskProgress = Self(rawValue: "task_progress")
            /// A background Claude task completed or failed and published its result location.
            public static let taskNotification = Self(rawValue: "task_notification")
            /// A Claude task changed status or moved between foreground and background execution.
            public static let taskUpdated = Self(rawValue: "task_updated")
            /// The agent session moved between running, idle, and waiting for user action.
            public static let sessionStateChanged = Self(rawValue: "session_state_changed")
        }

        public struct State: Codable, Hashable, RawRepresentable, Sendable {
            public var rawValue: String

            public init(rawValue: String) {
                self.rawValue = rawValue
            }

            /// The agent is actively processing a turn.
            public static let running = Self(rawValue: "running")
            /// The agent has no active turn.
            public static let idle = Self(rawValue: "idle")
            /// The agent paused until the user answers a prompt or grants permission.
            public static let requiresAction = Self(rawValue: "requires_action")
        }
    }

    public struct ResultEvent: Decodable, Hashable, Sendable {
        // public let type: EventType
        public let sessionID: String?
        public let usage: Usage
        // public let conductorSDKMetadata: JSONValue

        public struct Usage: Codable, Hashable, Sendable {
            public let inputTokens: Int
            public let outputTokens: Int
            public let cacheReadInputTokens: Int

            private enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
            }
        }

        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case usage
        }
    }

    // TODO: Feel like there's a better way to represent this (e.g. an enum), but might be better for the layer above (reducer)
    public struct ErrorEvent: Decodable, Hashable, Sendable {
        // public let type: EventType
        public let sessionID: String?
        public let content: String
        public let errorInfo: JSONValue?
        public let additionalDetails: String?
        public let willRetry: Bool?

        private enum CodingKeys: String, CodingKey {
            // case type
            case sessionID = "session_id"
            case content
            case errorInfo
            case additionalDetails
            case willRetry
        }
    }

    /*
    public struct Role: RawRepresentable, Codable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let assistant = Self(rawValue: "assistant")
        public static let user = Self(rawValue: "user")
    }
     */
}

public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected a JSON value."
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}
