//
//  AgentEventTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import CustomDump
import Foundation
@testable import ConductorMobileData
import Testing

@Suite("Agent event decoding")
struct AgentEventTests {
    @Test("Assistant messages retain their logical ID and usage snapshot")
    func assistantMessageIdentity() throws {
        let event = try decodeAgentEvent(
            #"{"type":"assistant","message":{"id":"message-1","model":"claude-opus-5","usage":{"input_tokens":42},"content":[]}}"#
        )

        expectNoDifference(
            event,
            .assistant(
                .init(
                    message: .init(
                        content: [],
                        id: "message-1",
                        model: "claude-opus-5",
                        usage: .object(["input_tokens": .integer(42)])
                    )
                )
            )
        )
    }

    @Test("Every nested event exposes its parent Agent tool call")
    func parentToolUseID() throws {
        let events = try [
            #"{"type":"assistant","parent_tool_use_id":"parent","message":{"content":[]}}"#,
            #"{"type":"user","parent_tool_use_id":"parent","message":{"content":[]}}"#,
            #"{"type":"system","parent_tool_use_id":"parent"}"#,
            #"{"type":"result","parent_tool_use_id":"parent"}"#,
            #"{"type":"error","parent_tool_use_id":"parent","content":"Failed"}"#,
            #"{"type":"future_event","parent_tool_use_id":"parent"}"#,
        ].map(decodeAgentEvent)

        expectNoDifference(
            events.map(\.parentToolUseID),
            Array(repeating: "parent", count: 6)
        )
    }

    @Test("Assistant events decode every observed content block")
    func assistantEvents() throws {
        let events = try [
            #"{"type":"assistant","session_id":"019cb186-53df-7aa0-9361-725d0c70a4fb","message":{"role":"assistant","content":[{"type":"text","text":"Ready."}]}}"#,
            #"{"type":"assistant","session_id":"019c5efa-3487-7500-8305-914f0ec7e314","message":{"role":"assistant","content":[{"type":"thinking","thinking":"[reasoning text intentionally omitted]"}]}}"#,
            #"{"type":"assistant","session_id":"019cc647-f80f-74b3-815d-9d7ec5d66392","message":{"model":"claude-opus-5","role":"assistant","content":[{"type":"tool_use","id":"item_1","name":"Bash","input":{"command":"pwd"}}]}}"#,
        ].map(decodeAgentEvent)

        expectNoDifference(
            events,
            [
                .assistant(
                    .init(
                        message: .init(
                            content: [
                                .text(.init(text: "Ready.")),
                            ]
                        )
                    )
                ),
                .assistant(
                    .init(
                        message: .init(
                            content: [
                                .thinking(.init(thinking: "[reasoning text intentionally omitted]")),
                            ]
                        )
                    )
                ),
                .assistant(
                    .init(
                        message: .init(
                            content: [
                                .toolUse(
                                    .init(
                                        id: "item_1",
                                        name: "Bash",
                                        input: ["command": .string("pwd")]
                                    )
                                ),
                            ],
                            model: "claude-opus-5"
                        )
                    )
                ),
            ]
        )
    }

    @Test("Environment events decode successful and failed tool results")
    func userEvents() throws {
        let events = try [
            #"{"type":"user","session_id":"019c5eec-0a6f-73b3-a7d2-0c5fd960f6f6","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"item_2","content":"","is_error":false}]}}"#,
            #"{"type":"user","session_id":"019cc69b-6178-7582-88c8-17c7d39db9aa","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"item_94","content":"  PID COMMAND\n","is_error":true}]}}"#,
        ].map(decodeAgentEvent)

        expectNoDifference(
            events,
            [
                .user(
                    .init(
                        sessionID: "019c5eec-0a6f-73b3-a7d2-0c5fd960f6f6",
                        message: .init(
                            content: [
                                .toolResult(
                                    .init(toolUseID: "item_2", content: "", isError: false)
                                ),
                            ]
                        )
                    )
                ),
                .user(
                    .init(
                        sessionID: "019cc69b-6178-7582-88c8-17c7d39db9aa",
                        message: .init(
                            content: [
                                .toolResult(
                                    .init(toolUseID: "item_94", content: "  PID COMMAND\n", isError: true)
                                ),
                            ]
                        )
                    )
                ),
            ]
        )
    }

    @Test("Every observed system event variation decodes")
    func systemEvents() throws {
        let events = try [
            #"{"type":"system","session_id":"019c5eec-0a6f-73b3-a7d2-0c5fd960f6f6"}"#,
            #"{"type":"system","subtype":"status","status":"compacting","session_id":"019ed317-f1d4-7e90-b540-5ba1c687b2b5"}"#,
            #"{"type":"system","subtype":"compact_boundary","session_id":"019eff98-3912-7a00-81ce-f11cfd862e6f","content":"Compacted from 143,300 to 4,499 tokens"}"#,
            #"{"type":"system","subtype":"session_state_changed","state":"running"}"#,
            #"{"type":"system","subtype":"session_state_changed","state":"idle"}"#,
        ].map(decodeAgentEvent)

        expectNoDifference(
            events,
            [
                .system(.init(subtype: nil, state: nil)),
                .system(.init(subtype: .status, state: nil, status: .compacting)),
                .system(
                    .init(
                        subtype: .compactBoundary,
                        state: nil,
                        content: "Compacted from 143,300 to 4,499 tokens"
                    )
                ),
                .system(.init(subtype: .sessionStateChanged, state: .running)),
                .system(.init(subtype: .sessionStateChanged, state: .idle)),
            ]
        )
    }

    @Test("Result events decode with and without SDK metadata")
    func resultEvents() throws {
        let events = try [
            #"{"type":"result","session_id":"019ed317-f1d4-7e90-b540-5ba1c687b2b5","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0}}"#,
            """
            {
              "type": "result",
              "session_id": "019f3942-a7a3-7b10-8b34-59049bbc5a91",
              "usage": {
                "input_tokens": 15456,
                "output_tokens": 21,
                "cache_read_input_tokens": 2432
              },
              "conductor_sdk_metadata": {
                "requestedModel": "gpt-5.5",
                "requestedReasoningEffort": null,
                "requestedServiceTier": null,
                "requestedFastMode": false,
                "requestedThinkingLevel": "none",
                "model": "gpt-5.5",
                "modelProvider": "openai",
                "reasoningEffort": "high",
                "serviceTier": null
              }
            }
            """,
        ].map(decodeAgentEvent)

        expectNoDifference(
            events,
            [
                .result(
                    .init(
                        sessionID: "019ed317-f1d4-7e90-b540-5ba1c687b2b5",
                        usage: .init(inputTokens: 0, outputTokens: 0, cacheReadInputTokens: 0)
                    )
                ),
                .result(
                    .init(
                        sessionID: "019f3942-a7a3-7b10-8b34-59049bbc5a91",
                        usage: .init(inputTokens: 15456, outputTokens: 21, cacheReadInputTokens: 2432)
                    )
                ),
            ]
        )
    }

    @Test("Claude result events normalize the active model context window")
    func resultContextWindow() throws {
        let event = try decodeAgentEvent(
            """
            {
              "type": "result",
              "conductor_sdk_metadata": {
                "requestedModel": "opus-5-1m",
                "model": "claude-opus-5[1m]"
              },
              "modelUsage": {
                "claude-opus-5[1m]": {
                  "contextWindow": 1000000
                },
                "claude-haiku-4-5-20251001": {
                  "contextWindow": 200000
                }
              }
            }
            """
        )

        guard case .result(let result) = event else {
            Issue.record("Expected a result event")
            return
        }
        expectNoDifference(
            result.contextWindowReport,
            .init(requestedModel: "opus-5-1m", tokenLimit: 1_000_000)
        )
    }

    @Test("Result context windows require matching active-model metadata")
    func resultContextWindowRequiresActiveModel() throws {
        let events = try [
            """
            {
              "type": "result",
              "conductor_sdk_metadata": {
                "requestedModel": "gpt-5.5",
                "model": "gpt-5.5"
              }
            }
            """,
            """
            {
              "type": "result",
              "conductor_sdk_metadata": {
                "requestedModel": "opus-5-1m",
                "model": "claude-opus-5[1m]"
              },
              "modelUsage": {
                "claude-haiku-4-5-20251001": {
                  "contextWindow": 200000
                }
              }
            }
            """,
        ].map(decodeAgentEvent)

        for event in events {
            guard case .result(let result) = event else {
                Issue.record("Expected a result event")
                continue
            }
            #expect(result.contextWindowReport == nil)
        }
    }

    @Test("Every observed error event variation decodes")
    func errorEvents() throws {
        let events = try [
            #"{"type":"error","content":"aborted by user"}"#,
            #"{"type":"error","session_id":"019f4a3a-c655-7292-8f58-27b5ee411796","content":"Selected model is at capacity. Please try a different model.","willRetry":false,"errorInfo":"serverOverloaded"}"#,
            #"{"type":"error","session_id":"019f49e6-34e1-7fe3-bbfa-2d011e16f4c7","content":"Reconnecting... 2/5","willRetry":true,"errorInfo":{"responseStreamDisconnected":{"httpStatusCode":null}},"additionalDetails":"request timed out"}"#,
        ].map(decodeAgentEvent)

        expectNoDifference(
            events,
            [
                .error(
                    .init(
                        sessionID: nil,
                        content: "aborted by user",
                        errorInfo: nil,
                        additionalDetails: nil,
                        willRetry: nil
                    )
                ),
                .error(
                    .init(
                        sessionID: "019f4a3a-c655-7292-8f58-27b5ee411796",
                        content: "Selected model is at capacity. Please try a different model.",
                        errorInfo: .string("serverOverloaded"),
                        additionalDetails: nil,
                        willRetry: false
                    )
                ),
                .error(
                    .init(
                        sessionID: "019f49e6-34e1-7fe3-bbfa-2d011e16f4c7",
                        content: "Reconnecting... 2/5",
                        errorInfo: .object([
                            "responseStreamDisconnected": .object([
                                "httpStatusCode": .null,
                            ]),
                        ]),
                        additionalDetails: "request timed out",
                        willRetry: true
                    )
                ),
            ]
        )
    }

    @Test("Unknown event and content types retain their complete JSON")
    func unknownValues() throws {
        let event = try decodeAgentEvent(
            #"{"type":"future_event","payload":{"enabled":true,"count":2}}"#
        )
        let assistantEvent = try decodeAgentEvent(
            #"{"type":"assistant","message":{"content":[{"type":"future_block","value":42}]}}"#
        )
        let userEvent = try decodeAgentEvent(
            #"{"type":"user","message":{"content":[{"type":"future_result","value":42}]}}"#
        )

        expectNoDifference(
            event,
            .unknown([
                "type": .string("future_event"),
                "payload": .object([
                    "enabled": .bool(true),
                    "count": .integer(2),
                ]),
            ])
        )
        expectNoDifference(
            assistantEvent,
            .assistant(
                .init(
                    message: .init(
                        content: [
                            .unknown([
                                "type": .string("future_block"),
                                "value": .integer(42),
                            ]),
                        ]
                    )
                )
            )
        )
        expectNoDifference(
            userEvent,
            .user(
                .init(
                    sessionID: nil,
                    message: .init(
                        content: [
                            .unknown([
                                "type": .string("future_result"),
                                "value": .integer(42),
                            ]),
                        ]
                    )
                )
            )
        )
    }

    @Test("JSON values round-trip every supported shape")
    func jsonValueRoundTrip() throws {
        let value: JSONValue = .object([
            "null": .null,
            "bool": .bool(false),
            "integer": .integer(42),
            "number": .number(1.5),
            "string": .string("value"),
            "array": .array([.string("ios"), .string("desktop")]),
            "object": .object(["status": .string("SUCCEEDED")]),
        ])

        let roundTripped = try JSONDecoder().decode(
            JSONValue.self,
            from: JSONEncoder().encode(value)
        )

        expectNoDifference(roundTripped, value)
    }

    @Test("Missing required payloads fail decoding")
    func missingRequiredPayloads() {
        let invalidEvents = [
            #"{"type":"assistant"}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"item_1"}]}}"#,
            #"{"type":"error"}"#,
        ]

        for event in invalidEvents {
            #expect(throws: DecodingError.self) {
                try decodeAgentEvent(event)
            }
        }
    }
}

private func decodeAgentEvent(_ json: String) throws -> AgentEvent {
    try JSONDecoder().decode(AgentEvent.self, from: Data(json.utf8))
}
