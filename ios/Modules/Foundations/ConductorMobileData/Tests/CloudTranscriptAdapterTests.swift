//
//  CloudTranscriptAdapterTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/28/26.
//

import ConductorCloud
import Foundation
import SharedConductorData
@testable import ConductorMobileData
import Testing

struct CloudTranscriptAdapterTests {
    @Test("Native Claude agent events retain their normalized payload")
    func nativeClaudeEvent() throws {
        let assistant = event(
            id: "assistant-event",
            index: 9,
            content: .object([
                "type": .string("agent"),
                "turnId": .string("turn-1"),
                "rawPayload": .object([
                    "type": .string("assistant"),
                    "message": .object([
                        "id": .string("message-1"),
                        "model": .string("claude-opus-5"),
                        "role": .string("assistant"),
                        "usage": .object(["input_tokens": .integer(42)]),
                        "content": .array([
                            .object([
                                "type": .string("text"),
                                "text": .string("The missing answer is visible."),
                            ]),
                        ]),
                    ]),
                    "session_id": .string("session"),
                ]),
            ])
        )

        let parts = CloudTranscriptAdapter.adapt(
            assistant,
            accountID: "account",
            remoteSessionID: "session",
            canonicalSessionID: "canonical-session"
        )

        let part = try #require(parts.first)
        #expect(parts.count == 1)
        #expect(part.message.role == .assistant)
        #expect(
            part.message.turnID
                == CloudCanonicalID.turn(
                    accountID: "account",
                    remoteSessionID: "session",
                    remoteTurnID: "turn-1"
                )
        )
        let content = try #require(part.message.content)
        guard case let .assistant(agentEvent) = try JSONDecoder().decode(
            AgentEvent.self,
            from: Data(content.utf8)
        ) else {
            Issue.record("Expected a native Claude assistant event.")
            return
        }
        guard case let .text(textBlock) = try #require(
            agentEvent.message.content.first
        ) else {
            Issue.record("Expected Claude assistant text.")
            return
        }
        #expect(textBlock.text == "The missing answer is visible.")
        #expect(agentEvent.message.id == "message-1")
        #expect(agentEvent.message.model == "claude-opus-5")
    }

    @Test("User and agent tool events adapt into canonical message rows")
    func understoodEvents() throws {
        let user = event(
            id: "user-event",
            index: 8,
            content: .object([
                "type": .string("userMessage"),
                "message": .string("Run the tests."),
                "turnId": .string("turn-1"),
                "senderId": .string("user-1"),
            ])
        )
        let command = event(
            id: "command-event",
            index: 9,
            content: agentContent(
                turnID: "turn-1",
                event: .object([
                    "type": .string("item.started"),
                    "item": .object([
                        "id": .string("command-1"),
                        "type": .string("commandExecution"),
                        "command": .string("mise -C ios run test"),
                    ]),
                ])
            )
        )

        let userParts = CloudTranscriptAdapter.adapt(
            user,
            accountID: "account",
            remoteSessionID: "session",
            canonicalSessionID: "canonical-session"
        )
        let commandParts = CloudTranscriptAdapter.adapt(
            command,
            accountID: "account",
            remoteSessionID: "session",
            canonicalSessionID: "canonical-session"
        )

        #expect(userParts.count == 1)
        #expect(userParts[0].message.role == .user)
        #expect(userParts[0].message.content == "Run the tests.")
        #expect(commandParts.count == 1)
        #expect(commandParts[0].message.role == .assistant)
        let commandData = try #require(
            commandParts[0].message.content?.data(using: .utf8)
        )
        guard case let .assistant(agentEvent) = try JSONDecoder().decode(
            AgentEvent.self,
            from: commandData
        ) else {
            Issue.record("Expected an assistant tool event.")
            return
        }
        #expect(agentEvent.message.content.count == 1)
        #expect(
            commandParts[0].message.turnID
                == CloudCanonicalID.turn(
                    accountID: "account",
                    remoteSessionID: "session",
                    remoteTurnID: "turn-1"
                )
        )
    }

    @Test("File changes produce deterministic ordered parts")
    func deterministicParts() {
        let fileChange = event(
            id: "file-event",
            index: 4,
            content: agentContent(
                turnID: "turn",
                event: .object([
                    "type": .string("item.started"),
                    "item": .object([
                        "id": .string("file-tool"),
                        "type": .string("fileChange"),
                        "changes": .array([
                            .object([
                                "path": .string("One.swift"),
                                "diff": .string("+one"),
                            ]),
                            .object([
                                "path": .string("Two.swift"),
                                "diff": .string("+two"),
                            ]),
                        ]),
                    ]),
                ])
            )
        )

        let first = CloudTranscriptAdapter.adapt(
            fileChange,
            accountID: "account",
            remoteSessionID: "session",
            canonicalSessionID: "canonical-session"
        )
        let second = CloudTranscriptAdapter.adapt(
            fileChange,
            accountID: "account",
            remoteSessionID: "session",
            canonicalSessionID: "canonical-session"
        )

        #expect(first == second)
        #expect(first.map(\.order) == [0, 1])
        #expect(Set(first.map(\.message.id)).count == 2)
    }

    @Test("Unsupported events remain invisible")
    func unsupportedEvent() {
        let unsupported = event(
            id: "future-event",
            index: 1,
            content: .object([
                "type": .string("futureEvent"),
                "payload": .object(["secret": .string("retained")]),
            ])
        )

        #expect(
            CloudTranscriptAdapter.adapt(
                unsupported,
                accountID: "account",
                remoteSessionID: "session",
                canonicalSessionID: "canonical-session"
            )
            .isEmpty
        )
    }
}

private func event(
    id: String,
    index: Double,
    content: CloudJSONValue
) -> CloudTranscriptMessage {
    CloudTranscriptMessage(
        id: id,
        sessionID: "session",
        sessionIndex: index,
        type: .init(rawValue: "agent"),
        content: content,
        receivedAt: Date(timeIntervalSince1970: index)
    )
}

private func agentContent(
    turnID: String,
    event: CloudJSONValue
) -> CloudJSONValue {
    .object([
        "type": .string("agent"),
        "turnId": .string(turnID),
        "rawPayload": .object(["event": event]),
    ])
}
