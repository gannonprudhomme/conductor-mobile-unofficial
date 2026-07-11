//
//  CodexEvent.swift
//  ConductorModules
//
//  Created by Gannon Prudomme on 7/10/26.
//

import Foundation

/// Parsed from ``Message/content`` whenever ``Message/role`` == ``Message/Role/assistant`` && {something}
public enum CodexEvent: Decodable, Equatable {
    case assistant(AssistantEvent)
    case user(UserEvent)
    case system
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
            self = .system
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
                    let container = try decoder.container(keyedBy: CodexEvent.AssistantEvent.AssistantMessage.AssistantMessageContent.CodingKeys.self)
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
                    let container = try decoder.container(keyedBy: CodexEvent.UserEvent.UserMessage.UserMessageContent.CodingKeys.self)
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
    
    /*
    public enum SystemEvent: Decodable, Hashable, Sendable {
        /**
         ```
         {
           "type": "system",
           "session_id": "019c5eec-0a6f-73b3-a7d2-0c5fd960f6f6"
         }
         ```
         */
         case lifecyleMarker(sessionID: String) // fuck if I know
        /**
         ```
         {
           "type": "system",
           "subtype": "status",
           "status": "compacting",
           "session_id": "019ed317-f1d4-7e90-b540-5ba1c687b2b5"
         }
         ```
         */
        case compacting
        /**
         ```
         {
           "type": "system",
           "subtype": "compact_boundary",
           "session_id": "019eff98-3912-7a00-81ce-f11cfd862e6f",
           "content": "Compacted from 143,300 to 4,499 tokens"
         }
         ```
         */
        case compactBoundary
        case unknown([String: JSONValue])
    }
    */
    
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
