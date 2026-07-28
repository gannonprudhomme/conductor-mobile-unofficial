//
//  CloudTranscriptAdapter.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/27/26.
//

import ConductorCloud
import Foundation
import SharedConductorData

public struct AdaptedCloudMessage: Equatable, Sendable {
    public let sourceMessageID: CloudTranscriptMessage.ID
    public let message: Message

    public init(
        sourceMessageID: CloudTranscriptMessage.ID,
        message: Message
    ) {
        self.sourceMessageID = sourceMessageID
        self.message = message
    }
}

public enum CloudTranscriptAdapter {
    public static func adapt(
        _ transcriptMessages: [CloudTranscriptMessage]
    ) -> [AdaptedCloudMessage] {
        CloudTranscriptMessage.normalized(transcriptMessages)
            .flatMap(adapt)
    }

    public static func adapt(
        _ transcriptMessage: CloudTranscriptMessage
    ) -> [AdaptedCloudMessage] {
        transcriptMessage.adaptedMessages
    }
}

private extension CloudTranscriptMessage {
    var adaptedMessages: [AdaptedCloudMessage] {
        guard case let .object(content) = content,
              let contentType = content["type"]?.stringValue
        else {
            return unsupportedMessages(label: "Unknown Cloud transcript content")
        }

        let turnID = content["turnId"]?.stringValue ?? id
        switch contentType {
        case "userMessage":
            guard let text = content["message"]?.stringValue else {
                return unsupportedMessages(label: "Unsupported user message")
            }
            return wrap(
                Message(
                    id: id,
                    sessionID: sessionID,
                    role: .user,
                    content: text,
                    createdAt: receivedAt,
                    sentAt: receivedAt,
                    turnID: turnID,
                    senderID: content["senderId"]?.stringValue
                )
            )

        case "assistantMessage":
            guard let text = content["message"]?.stringValue
                ?? content["text"]?.stringValue else {
                return unsupportedMessages(label: "Unsupported assistant message")
            }
            return eventMessages(
                event: assistantEvent(
                    content: [
                        "type": "text",
                        "text": text,
                    ]
                ),
                turnID: turnID
            )

        case "agent":
            guard case let .object(rawPayload) = content["rawPayload"],
                  case let .object(event) = rawPayload["event"] else {
                return unsupportedMessages(label: "Unsupported agent payload")
            }
            return normalizedAgentMessages(event: event, turnID: turnID)

        case "error":
            return eventMessages(
                event: [
                    "type": "error",
                    "content": content["message"]?.displayString
                        ?? "The cloud agent reported an error.",
                    "willRetry": false,
                ],
                turnID: turnID
            )

        default:
            return unsupportedMessages(
                label: "Unsupported Cloud transcript type: \(contentType)"
            )
        }
    }

    func normalizedAgentMessages(
        event: [String: CloudJSONValue],
        turnID: String
    ) -> [AdaptedCloudMessage] {
        guard let eventType = event["type"]?.stringValue else {
            return unsupportedMessages(label: "Unknown Cloud agent event")
        }

        switch eventType {
        case "item.started", "item.completed":
            guard case let .object(item) = event["item"],
                  let itemType = item["type"]?.stringValue else {
                return unsupportedMessages(label: "Unsupported Cloud agent item")
            }
            return normalizedItemMessages(
                item,
                itemType: itemType,
                isCompleted: eventType == "item.completed",
                turnID: turnID
            )

        case "turn.completed":
            return eventMessages(
                event: [
                    "type": "result",
                    "usage": [
                        "input_tokens": 0,
                        "output_tokens": 0,
                        "cache_read_input_tokens": 0,
                    ],
                ],
                turnID: turnID
            )

        case "turn.failed", "error":
            return eventMessages(
                event: [
                    "type": "error",
                    "content": event["error"]?.displayString
                        ?? event["message"]?.stringValue
                        ?? "The cloud agent reported an error.",
                    "willRetry": false,
                ],
                turnID: turnID
            )

        default:
            return unsupportedMessages(
                label: "Unsupported Cloud agent event: \(eventType)"
            )
        }
    }

    func normalizedItemMessages(
        _ item: [String: CloudJSONValue],
        itemType: String,
        isCompleted: Bool,
        turnID: String
    ) -> [AdaptedCloudMessage] {
        let toolUseID = item["id"]?.stringValue ?? id

        switch (itemType, isCompleted) {
        case ("agentMessage", true):
            guard let text = item["text"]?.stringValue, !text.isEmpty else {
                return []
            }
            return eventMessages(
                event: assistantEvent(
                    content: [
                        "type": "text",
                        "text": text,
                    ]
                ),
                turnID: turnID
            )

        case ("commandExecution", false):
            return eventMessages(
                event: assistantEvent(
                    content: toolUse(
                        id: toolUseID,
                        name: "Bash",
                        input: [
                            "command": item["command"]?.stringValue ?? "",
                        ]
                    )
                ),
                turnID: turnID
            )

        case ("commandExecution", true):
            let status = item["status"]?.stringValue
            let exitCode = item["exitCode"]?.integerValue
            return eventMessages(
                event: toolResult(
                    id: toolUseID,
                    content: item["aggregatedOutput"]?.stringValue ?? "",
                    isError: status == "failed"
                        || (exitCode.map { $0 != 0 } ?? false)
                ),
                turnID: turnID
            )

        case ("imageView", false):
            return eventMessages(
                event: assistantEvent(
                    content: toolUse(
                        id: toolUseID,
                        name: "Read",
                        input: [
                            "file_path": item["path"]?.stringValue ?? "",
                        ]
                    )
                ),
                turnID: turnID
            )

        case ("imageView", true):
            return eventMessages(
                event: toolResult(
                    id: toolUseID,
                    content: "",
                    isError: false
                ),
                turnID: turnID
            )

        case ("mcpToolCall", false):
            let server = item["server"]?.stringValue ?? "unknown"
            let tool = item["tool"]?.stringValue ?? "unknown"
            return eventMessages(
                event: assistantEvent(
                    content: toolUse(
                        id: toolUseID,
                        name: "mcp__\(server)__\(tool)",
                        input: item["arguments"]?.foundationObject ?? [:]
                    )
                ),
                turnID: turnID
            )

        case ("mcpToolCall", true):
            let status = item["status"]?.stringValue
            let error = item["error"]?.displayString
            return eventMessages(
                event: toolResult(
                    id: toolUseID,
                    content: error
                        ?? item["result"]?.displayString
                        ?? "",
                    isError: error != nil || status == "failed"
                ),
                turnID: turnID
            )

        case ("fileChange", _):
            guard case let .array(changes) = item["changes"] else {
                return unsupportedMessages(label: "Unsupported file change")
            }
            return changes.enumerated().flatMap { index, change in
                guard case let .object(change) = change else {
                    return unsupportedMessages(
                        label: "Unsupported file change",
                        idSuffix: index
                    )
                }
                let changeID = "\(toolUseID):\(index)"
                if isCompleted {
                    return eventMessages(
                        event: toolResult(
                            id: changeID,
                            content: "",
                            isError: item["status"]?.stringValue == "failed"
                        ),
                        turnID: turnID,
                        idSuffix: index
                    )
                }
                return eventMessages(
                    event: assistantEvent(
                        content: toolUse(
                            id: changeID,
                            name: "Edit",
                            input: [
                                "file_path": change["path"]?.stringValue ?? "",
                                "old_string": "",
                                "new_string": change["diff"]?.stringValue ?? "",
                            ]
                        )
                    ),
                    turnID: turnID,
                    idSuffix: index
                )
            }

        default:
            return unsupportedMessages(
                label: "Unsupported Cloud agent item: \(itemType)"
            )
        }
    }

    func unsupportedMessages(
        label: String,
        idSuffix: Int? = nil
    ) -> [AdaptedCloudMessage] {
        eventMessages(
            event: assistantEvent(
                content: [
                    "type": "text",
                    "text": label,
                ]
            ),
            turnID: id,
            idSuffix: idSuffix
        )
    }

    func eventMessages(
        event: [String: Any],
        turnID: String,
        idSuffix: Int? = nil
    ) -> [AdaptedCloudMessage] {
        guard JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(
                  withJSONObject: event,
                  options: .sortedKeys
              ),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }
        return wrap(
            Message(
                id: idSuffix.map { "\(id):\($0)" } ?? id,
                sessionID: sessionID,
                role: .assistant,
                content: content,
                createdAt: receivedAt,
                sentAt: receivedAt,
                turnID: turnID
            )
        )
    }

    func wrap(_ message: Message) -> [AdaptedCloudMessage] {
        [
            AdaptedCloudMessage(
                sourceMessageID: id,
                message: message
            ),
        ]
    }

    func assistantEvent(content: [String: Any]) -> [String: Any] {
        [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [content],
            ],
        ]
    }

    func toolUse(
        id: String,
        name: String,
        input: [String: Any]
    ) -> [String: Any] {
        [
            "type": "tool_use",
            "id": id,
            "name": name,
            "input": input,
        ]
    }

    func toolResult(
        id: String,
        content: String,
        isError: Bool
    ) -> [String: Any] {
        [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": id,
                        "content": content,
                        "is_error": isError,
                    ],
                ],
            ],
        ]
    }
}

private extension CloudJSONValue {
    var stringValue: String? {
        guard case let .string(value) = self else {
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

    var foundationObject: [String: Any]? {
        guard case let .object(value) = self else {
            return nil
        }
        return value.mapValues(\.foundationValue)
    }

    var foundationValue: Any {
        switch self {
        case .null:
            NSNull()
        case let .bool(value):
            value
        case let .integer(value):
            value
        case let .number(value):
            value
        case let .string(value):
            value
        case let .array(value):
            value.map(\.foundationValue)
        case let .object(value):
            value.mapValues(\.foundationValue)
        }
    }

    var displayString: String? {
        if let stringValue {
            return stringValue
        }
        guard JSONSerialization.isValidJSONObject(foundationValue),
              let data = try? JSONSerialization.data(
                  withJSONObject: foundationValue,
                  options: .sortedKeys
              ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
