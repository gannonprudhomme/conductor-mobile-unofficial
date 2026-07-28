//
//  CloudTranscriptAdapter.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/28/26.
//

import ConductorCloud
import Foundation
import SharedConductorData

public enum CloudTranscriptAdapter {
    public static let projectionVersion = 1

    public struct Part: Equatable, Sendable {
        public let message: Message
        public let order: Int

        public init(message: Message, order: Int) {
            self.message = message
            self.order = order
        }
    }

    public static func adapt(
        _ event: CloudTranscriptMessage,
        accountID: String,
        remoteSessionID: String,
        canonicalSessionID: Session.ID
    ) -> [Part] {
        guard case let .object(content) = event.content,
              let contentType = content["type"]?.stringValue else {
            return []
        }

        let remoteTurnID = content["turnId"]?.stringValue ?? event.id
        let turnID = CloudCanonicalID.turn(
            accountID: accountID,
            remoteSessionID: remoteSessionID,
            remoteTurnID: remoteTurnID
        )
        switch contentType {
        case "userMessage":
            guard let text = content["message"]?.stringValue else {
                return []
            }
            return [
                part(
                    event: event,
                    accountID: accountID,
                    remoteSessionID: remoteSessionID,
                    canonicalSessionID: canonicalSessionID,
                    order: 0,
                    role: .user,
                    content: text,
                    turnID: turnID,
                    model: content["config"]?.objectValue?["model"]?.stringValue,
                    senderID: content["senderId"]?.stringValue
                ),
            ]

        case "assistantMessage":
            guard let text = content["message"]?.stringValue
                ?? content["text"]?.stringValue else {
                return []
            }
            return agentParts(
                event: event,
                accountID: accountID,
                remoteSessionID: remoteSessionID,
                canonicalSessionID: canonicalSessionID,
                turnID: turnID,
                payloads: [assistantEvent(text: text)]
            )

        case "agent":
            guard let rawPayload = content["rawPayload"]?.objectValue,
                  let agentEvent = rawPayload["event"]?.objectValue else {
                return []
            }
            return adaptAgentEvent(
                agentEvent,
                event: event,
                accountID: accountID,
                remoteSessionID: remoteSessionID,
                canonicalSessionID: canonicalSessionID,
                turnID: turnID
            )

        case "toolResult":
            let remoteToolID = content["toolUseId"]?.stringValue
                ?? content["toolCallId"]?.stringValue
                ?? event.id
            return agentParts(
                event: event,
                accountID: accountID,
                remoteSessionID: remoteSessionID,
                canonicalSessionID: canonicalSessionID,
                turnID: turnID,
                payloads: [
                    toolResultEvent(
                        toolID: CloudCanonicalID.tool(
                            accountID: accountID,
                            remoteSessionID: remoteSessionID,
                            remoteToolID: remoteToolID
                        ),
                        content: content["result"]?.displayString
                            ?? content["content"]?.displayString
                            ?? "",
                        isError: content["isError"]?.boolValue == true
                    ),
                ]
            )

        case "error":
            return agentParts(
                event: event,
                accountID: accountID,
                remoteSessionID: remoteSessionID,
                canonicalSessionID: canonicalSessionID,
                turnID: turnID,
                payloads: [
                    errorEvent(
                        content["message"]?.stringValue
                            ?? content["error"]?.displayString
                            ?? "The cloud agent reported an error."
                    ),
                ]
            )

        default:
            return []
        }
    }

    private static func adaptAgentEvent(
        _ agentEvent: [String: CloudJSONValue],
        event: CloudTranscriptMessage,
        accountID: String,
        remoteSessionID: String,
        canonicalSessionID: Session.ID,
        turnID: String
    ) -> [Part] {
        guard let eventType = agentEvent["type"]?.stringValue else {
            return []
        }

        let payloads: [[String: CloudJSONValue]]
        switch eventType {
        case "item.started", "item.completed":
            guard let item = agentEvent["item"]?.objectValue,
                  let itemType = item["type"]?.stringValue else {
                return []
            }
            payloads = itemEvents(
                item,
                itemType: itemType,
                isCompleted: eventType == "item.completed",
                accountID: accountID,
                remoteSessionID: remoteSessionID,
                fallbackToolID: event.id
            )

        case "turn.completed":
            payloads = [resultEvent()]

        case "turn.failed", "error":
            payloads = [
                errorEvent(
                    agentEvent["error"]?.displayString
                        ?? agentEvent["message"]?.stringValue
                        ?? "The cloud agent reported an error."
                ),
            ]

        default:
            return []
        }

        return agentParts(
            event: event,
            accountID: accountID,
            remoteSessionID: remoteSessionID,
            canonicalSessionID: canonicalSessionID,
            turnID: turnID,
            payloads: payloads
        )
    }

    private static func itemEvents(
        _ item: [String: CloudJSONValue],
        itemType: String,
        isCompleted: Bool,
        accountID: String,
        remoteSessionID: String,
        fallbackToolID: String
    ) -> [[String: CloudJSONValue]] {
        let remoteToolID = item["id"]?.stringValue ?? fallbackToolID
        let toolID = CloudCanonicalID.tool(
            accountID: accountID,
            remoteSessionID: remoteSessionID,
            remoteToolID: remoteToolID
        )

        switch (itemType, isCompleted) {
        case ("agentMessage", true):
            guard let text = item["text"]?.stringValue, !text.isEmpty else {
                return []
            }
            return [assistantEvent(text: text)]

        case ("commandExecution", false):
            return [
                assistantToolEvent(
                    toolID: toolID,
                    name: "Bash",
                    input: [
                        "command": item["command"] ?? .string(""),
                    ]
                ),
            ]

        case ("commandExecution", true):
            let exitCode = item["exitCode"]?.integerValue
            return [
                toolResultEvent(
                    toolID: toolID,
                    content: item["aggregatedOutput"]?.stringValue ?? "",
                    isError: item["status"]?.stringValue == "failed"
                        || exitCode.map { $0 != 0 } == true
                ),
            ]

        case ("imageView", false):
            return [
                assistantToolEvent(
                    toolID: toolID,
                    name: "Read",
                    input: [
                        "file_path": item["path"] ?? .string(""),
                    ]
                ),
            ]

        case ("imageView", true):
            return [toolResultEvent(toolID: toolID, content: "", isError: false)]

        case ("mcpToolCall", false):
            let server = item["server"]?.stringValue ?? "unknown"
            let tool = item["tool"]?.stringValue ?? "unknown"
            return [
                assistantToolEvent(
                    toolID: toolID,
                    name: "mcp__\(server)__\(tool)",
                    input: item["arguments"]?.objectValue ?? [:]
                ),
            ]

        case ("mcpToolCall", true):
            let error = item["error"]?.displayString
            return [
                toolResultEvent(
                    toolID: toolID,
                    content: error ?? item["result"]?.displayString ?? "",
                    isError: error != nil || item["status"]?.stringValue == "failed"
                ),
            ]

        case ("fileChange", _):
            guard let changes = item["changes"]?.arrayValue else {
                return []
            }
            return changes.enumerated().compactMap { index, value in
                guard let change = value.objectValue else {
                    return nil
                }
                let changeToolID = CloudCanonicalID.tool(
                    accountID: accountID,
                    remoteSessionID: remoteSessionID,
                    remoteToolID: "\(remoteToolID):\(index)"
                )
                if isCompleted {
                    return toolResultEvent(
                        toolID: changeToolID,
                        content: "",
                        isError: item["status"]?.stringValue == "failed"
                    )
                }
                return assistantToolEvent(
                    toolID: changeToolID,
                    name: "Edit",
                    input: [
                        "file_path": change["path"] ?? .string(""),
                        "old_string": .string(""),
                        "new_string": change["diff"] ?? .string(""),
                    ]
                )
            }

        default:
            return []
        }
    }

    private static func agentParts(
        event: CloudTranscriptMessage,
        accountID: String,
        remoteSessionID: String,
        canonicalSessionID: Session.ID,
        turnID: String,
        payloads: [[String: CloudJSONValue]]
    ) -> [Part] {
        payloads.enumerated().compactMap { order, payload in
            guard let content = encoded(payload) else {
                return nil
            }
            return part(
                event: event,
                accountID: accountID,
                remoteSessionID: remoteSessionID,
                canonicalSessionID: canonicalSessionID,
                order: order,
                role: .assistant,
                content: content,
                turnID: turnID
            )
        }
    }

    private static func part(
        event: CloudTranscriptMessage,
        accountID: String,
        remoteSessionID: String,
        canonicalSessionID: Session.ID,
        order: Int,
        role: Message.Role,
        content: String,
        turnID: String,
        model: String? = nil,
        senderID: String? = nil
    ) -> Part {
        Part(
            message: Message(
                id: CloudCanonicalID.message(
                    accountID: accountID,
                    remoteSessionID: remoteSessionID,
                    eventID: event.id,
                    partOrder: order
                ),
                sessionID: canonicalSessionID,
                role: role,
                content: content,
                createdAt: event.receivedAt,
                sentAt: event.receivedAt,
                model: model,
                turnID: turnID,
                senderID: senderID
            ),
            order: order
        )
    }

    private static func assistantEvent(text: String) -> [String: CloudJSONValue] {
        [
            "type": .string("assistant"),
            "message": .object([
                "role": .string("assistant"),
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(text),
                    ]),
                ]),
            ]),
        ]
    }

    private static func assistantToolEvent(
        toolID: String,
        name: String,
        input: [String: CloudJSONValue]
    ) -> [String: CloudJSONValue] {
        [
            "type": .string("assistant"),
            "message": .object([
                "role": .string("assistant"),
                "content": .array([
                    .object([
                        "type": .string("tool_use"),
                        "id": .string(toolID),
                        "name": .string(name),
                        "input": .object(input),
                    ]),
                ]),
            ]),
        ]
    }

    private static func toolResultEvent(
        toolID: String,
        content: String,
        isError: Bool
    ) -> [String: CloudJSONValue] {
        [
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .array([
                    .object([
                        "type": .string("tool_result"),
                        "tool_use_id": .string(toolID),
                        "content": .string(content),
                        "is_error": .bool(isError),
                    ]),
                ]),
            ]),
        ]
    }

    private static func resultEvent() -> [String: CloudJSONValue] {
        [
            "type": .string("result"),
            "usage": .object([
                "input_tokens": .integer(0),
                "output_tokens": .integer(0),
                "cache_read_input_tokens": .integer(0),
            ]),
        ]
    }

    private static func errorEvent(_ message: String) -> [String: CloudJSONValue] {
        [
            "type": .string("error"),
            "content": .string(message),
            "willRetry": .bool(false),
        ]
    }

    private static func encoded(
        _ payload: [String: CloudJSONValue]
    ) -> String? {
        guard let data = try? JSONEncoder.sorted.encode(payload) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension CloudJSONValue {
    var arrayValue: [Self]? {
        guard case let .array(value) = self else {
            return nil
        }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else {
            return nil
        }
        return value
    }

    var integerValue: Int64? {
        switch self {
        case let .integer(value):
            value
        case let .number(value):
            Int64(exactly: value)
        default:
            nil
        }
    }

    var objectValue: [String: Self]? {
        guard case let .object(value) = self else {
            return nil
        }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }

    var displayString: String {
        switch self {
        case .null:
            "null"
        case let .bool(value):
            String(value)
        case let .integer(value):
            String(value)
        case let .number(value):
            String(value)
        case let .string(value):
            value
        case .array, .object:
            encodedDescription
        }
    }

    private var encodedDescription: String {
        guard let data = try? JSONEncoder.sorted.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }
}
