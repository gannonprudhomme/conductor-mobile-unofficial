//
//  CloudTranscriptAdapterTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/27/26.
//

import ConductorCloud
@testable import ConductorMobileData
import Foundation
import SharedConductorData
import Testing

struct CloudTranscriptAdapterTests {
    @Test("Sanitized Cloud events map into deterministic canonical rows")
    func representativeEvents() throws {
        let messages = [
            userMessage(id: "user", text: "Please inspect the workspace.", index: 1),
            agentMessage(
                id: "assistant",
                index: 2,
                event: [
                    "type": .string("item.completed"),
                    "item": .object([
                        "id": .string("assistant-item"),
                        "type": .string("agentMessage"),
                        "text": .string("I will inspect it."),
                    ]),
                ]
            ),
            agentMessage(
                id: "command",
                index: 3,
                event: [
                    "type": .string("item.started"),
                    "item": .object([
                        "id": .string("command-item"),
                        "type": .string("commandExecution"),
                        "command": .string("git status --short"),
                    ]),
                ]
            ),
            agentMessage(
                id: "result",
                index: 4,
                event: [
                    "type": .string("item.completed"),
                    "item": .object([
                        "id": .string("command-item"),
                        "type": .string("commandExecution"),
                        "status": .string("completed"),
                        "exitCode": .integer(0),
                        "aggregatedOutput": .string("clean"),
                    ]),
                ]
            ),
            agentMessage(
                id: "error",
                index: 5,
                event: [
                    "type": .string("turn.failed"),
                    "message": .string("Synthetic failure"),
                ]
            ),
        ]

        let adapted = CloudTranscriptAdapter.adapt(messages)

        #expect(adapted.map(\.message.id) == messages.map(\.id))
        #expect(adapted.first?.message.role == .user)
        #expect(adapted.first?.message.content == "Please inspect the workspace.")
        #expect(adapted[1].message.content?.contains("\"type\":\"assistant\"") == true)
        #expect(adapted[2].message.content?.contains("\"name\":\"Bash\"") == true)
        #expect(adapted[3].message.content?.contains("\"type\":\"tool_result\"") == true)
        #expect(adapted[4].message.content?.contains("Synthetic failure") == true)

    }

    @Test("Duplicate IDs update in place and unknown shapes remain renderable")
    func duplicateAndUnknownEvents() {
        let older = userMessage(id: "stable", text: "older", index: 1)
        let newer = userMessage(id: "stable", text: "newer", index: 1)
        let unknown = CloudTranscriptMessage(
            id: "unknown",
            sessionID: "session",
            sessionIndex: 2,
            type: .init(rawValue: "future"),
            content: .object([
                "type": .string("futureTranscriptShape"),
                "secret": .string("transport-only-value"),
            ]),
            receivedAt: date.addingTimeInterval(2)
        )

        let adapted = CloudTranscriptAdapter.adapt([older, unknown, newer])

        #expect(adapted.count == 2)
        #expect(adapted[0].message.content == "newer")
        #expect(
            adapted[1].message.content?.contains(
                "Unsupported Cloud transcript type"
            ) == true
        )
        #expect(adapted[1].message.content?.contains("transport-only-value") == false)
    }

    private static let date = Date(timeIntervalSince1970: 1_783_555_200)

    private var date: Date { Self.date }

    private func userMessage(
        id: String,
        text: String,
        index: Double
    ) -> CloudTranscriptMessage {
        CloudTranscriptMessage(
            id: id,
            sessionID: "session",
            sessionIndex: index,
            type: .init(rawValue: "event"),
            content: .object([
                "type": .string("userMessage"),
                "message": .string(text),
                "turnId": .string("turn"),
            ]),
            receivedAt: date.addingTimeInterval(index)
        )
    }

    private func agentMessage(
        id: String,
        index: Double,
        event: [String: CloudJSONValue]
    ) -> CloudTranscriptMessage {
        CloudTranscriptMessage(
            id: id,
            sessionID: "session",
            sessionIndex: index,
            type: .init(rawValue: "event"),
            content: .object([
                "type": .string("agent"),
                "turnId": .string("turn"),
                "rawPayload": .object([
                    "event": .object(event),
                ]),
            ]),
            receivedAt: date.addingTimeInterval(index)
        )
    }
}
