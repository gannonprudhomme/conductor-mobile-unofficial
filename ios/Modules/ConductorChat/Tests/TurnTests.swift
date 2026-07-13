//
//  TurnTests.swift
//  ConductorChatTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import ConductorMobileData
import CustomDump
import Foundation
@testable import ConductorChat
import Testing

@Suite("Turn parsing")
struct TurnTests {
    @Test("Human messages find file-reference labels")
    @MainActor
    func humanMessageFileReferences() {
        let references = HumanMessageRowView.fileReferences(
            in: "Review @⟦Transcript.md⟧(.context%2Fattachments%2Fabc%2FTranscript.md), @⟦Added.swift +10-12⟧(.context%2Fattachments%2Fcomments%2Fadded.md), and @⟦Removed.swift -10⟧(.context%2Fattachments%2Fcomments%2Fremoved.md)."
        )

        expectNoDifference(
            references.map(\.label),
            ["Transcript.md", "Added.swift", "Removed.swift"]
        )
    }

    @Test("A complete real database turn becomes human and assistant rows")
    func completeRealTurn() throws {
        let messages = try JSONDecoder.conductor.decode(
            [Message].self,
            from: Data(Self.completeTurnJSON.utf8)
        )
        let startedAt = try #require(messages.first?.sentAt)

        expectNoDifference(
            Turn.parse(messages: messages).map(\.testProjection),
            [
                TurnProjection(
                    id: "42a0e1cf-2f00-47fb-9f60-e3192a155ac4",
                    startedAt: startedAt,
                    rows: [
                        .humanMessage(
                            id: "42a0e1cf-2f00-47fb-9f60-e3192a155ac4",
                            content: "test"
                        ),
                        .assistantText(
                            messageID: "10d56140-7118-450e-b59d-b476803688da",
                            renderedChunks: ["Ready."],
                            isMostRecentTextInTurn: true
                        ),
                    ]
                ),
            ]
        )
    }

    @Test("Turns preserve first-seen turn order and row order")
    func groupingAndOrdering() throws {
        let messages = try [
            makeStoredMessage(id: "human-a", role: "user", content: "First", turnID: "turn-a"),
            makeStoredMessage(id: "human-b", role: "user", content: "Second", turnID: "turn-b"),
            makeEventMessage(
                id: "assistant-a",
                event: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Answer first"}]}}"#,
                turnID: "turn-a"
            ),
            makeEventMessage(
                id: "assistant-b",
                event: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Answer second"}]}}"#,
                turnID: "turn-b"
            ),
        ]
        let startedAt = try #require(messages.first?.createdAt)

        expectNoDifference(
            Turn.parse(messages: messages).map(\.testProjection),
            [
                TurnProjection(
                    id: "turn-a",
                    startedAt: startedAt,
                    rows: [
                        .humanMessage(id: "human-a", content: "First"),
                        .assistantText(
                            messageID: "assistant-a",
                            renderedChunks: ["Answer first"],
                            isMostRecentTextInTurn: true
                        ),
                    ]
                ),
                TurnProjection(
                    id: "turn-b",
                    startedAt: startedAt,
                    rows: [
                        .humanMessage(id: "human-b", content: "Second"),
                        .assistantText(
                            messageID: "assistant-b",
                            renderedChunks: ["Answer second"],
                            isMostRecentTextInTurn: true
                        ),
                    ]
                ),
            ]
        )
    }

    @Test("Only the most recent text row in each turn is marked as most recent")
    func mostRecentText() throws {
        let messages = try [
            makeEventMessage(
                id: "first-text",
                event: #"{"type":"assistant","message":{"content":[{"type":"text","text":"First"}]}}"#,
                turnID: "turn-1"
            ),
            makeEventMessage(
                id: "tool",
                event: #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-1","name":"Read","input":{"file_path":"File.swift"}}]}}"#,
                turnID: "turn-1"
            ),
            makeEventMessage(
                id: "latest-text",
                event: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Latest"}]}}"#,
                turnID: "turn-1"
            ),
        ]

        expectNoDifference(
            Turn.parse(messages: messages).first?.rows.map(\.testProjection),
            [
                .assistantText(
                    messageID: "first-text",
                    renderedChunks: ["First"],
                    isMostRecentTextInTurn: false
                ),
                .assistantToolCall(
                    messageID: "tool",
                    toolCall: .readFile(toolUseID: "tool-1", filePath: "File.swift")
                ),
                .assistantText(
                    messageID: "latest-text",
                    renderedChunks: ["Latest"],
                    isMostRecentTextInTurn: true
                ),
            ]
        )
    }

    @Test("Assistant Markdown is parsed into its stable presentation row")
    func assistantMarkdownContent() throws {
        let message = try makeEventMessage(
            id: "markdown",
            event: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Use **Markdown**."}]}}"#,
            turnID: "turn-1"
        )
        let row = try #require(Turn.parse(messages: [message]).first?.rows.first)
        guard case let .assistantMessage(.text(_, content, _)) = row else {
            Issue.record("Expected an assistant text row")
            return
        }

        let chunk = try #require(content.chunks.first)
        #expect(content.chunks.count == 1)
        #expect(chunk.id == 0)
        #expect(chunk.markdown.renderPlainText() == "Use Markdown.")
    }

    @Test("Changed assistant Markdown replaces reusable presentation content")
    func changedAssistantMarkdownReplacesReusableContent() throws {
        let initialMessage = try makeEventMessage(
            id: "markdown",
            event: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Before"}]}}"#,
            turnID: "turn-1"
        )
        let updatedMessage = try makeEventMessage(
            id: "markdown",
            event: #"{"type":"assistant","message":{"content":[{"type":"text","text":"After **update**"}]}}"#,
            turnID: "turn-1"
        )
        let initialTurns = Turn.parse(messages: [initialMessage])
        let updatedRow = try #require(
            Turn.parse(messages: [updatedMessage], reusing: initialTurns).first?.rows.first
        )
        guard case let .assistantMessage(.text(_, content, _)) = updatedRow else {
            Issue.record("Expected an assistant text row")
            return
        }

        #expect(try #require(content.chunks.first).markdown.renderPlainText() == "After update")
    }

    @Test("Unchanged assistant Markdown reuses parsed presentation content")
    func unchangedAssistantMarkdownReusesPresentationContent() throws {
        let message = try makeEventMessage(
            id: "markdown",
            event: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Reuse **this**"}]}}"#,
            turnID: "turn-1"
        )
        let initialTurns = Turn.parse(messages: [message])
        let initialRow = try #require(initialTurns.first?.rows.first)
        let reusedRow = try #require(
            Turn.parse(messages: [message], reusing: initialTurns).first?.rows.first
        )
        guard case let .assistantMessage(.text(_, initialContent, _)) = initialRow,
              case let .assistantMessage(.text(_, reusedContent, _)) = reusedRow else {
            Issue.record("Expected assistant text rows")
            return
        }

        let sharesParsedChunkStorage = initialContent.chunks.withUnsafeBufferPointer { initial in
            reusedContent.chunks.withUnsafeBufferPointer { reused in
                initial.baseAddress == reused.baseAddress
            }
        }
        #expect(sharesParsedChunkStorage)
        #expect(try #require(reusedContent.chunks.first).markdown.renderPlainText() == "Reuse this")
    }

    @Test("Detached Markdown chunks preserve reference resolution")
    func assistantMarkdownReferenceDefinitions() throws {
        let introduction = "Intro " + String(repeating: "a", count: 2_474)
        let content = Turn.Row.AssistantMessage.TextContent(
            introduction + "\n\n" + """
            Read [documentation][docs].

            [docs]: https://example.com
            """
        )

        try #require(content.chunks.count == 2)
        #expect(
            content.chunks[1].markdown.renderMarkdown().contains(
                "[documentation](https://example.com)"
            )
        )
    }

    @Test("Markdown chunk boundaries preserve collapsed margins")
    func assistantMarkdownChunkSpacing() {
        typealias Spacing = Turn.Row.AssistantMessage.TextContent.Chunk.Spacing
        let oversizedParagraph = String(repeating: "a", count: 2_001)
        let spacing: ([String]) -> [Spacing] = {
            Turn.Row.AssistantMessage.TextContent(
                $0.joined(separator: "\n\n")
            ).chunks.map(\.spacingBefore)
        }

        expectNoDifference(
            spacing([oversizedParagraph, oversizedParagraph]),
            [.none, .standard]
        )
        expectNoDifference(
            spacing([oversizedParagraph, "## Heading", oversizedParagraph]),
            [.none, .heading, .standard]
        )
        expectNoDifference(
            spacing([oversizedParagraph, "---", oversizedParagraph]),
            [.none, .thematicBreak, .thematicBreak]
        )

        expectNoDifference(
            [Spacing.none, .standard, .heading, .thematicBreak].map {
                $0.additionalTopPadding(rootFontSize: 16, existingSpacing: 16)
            },
            [0, 0, 8, 16]
        )
    }

    @Test("Assistant Markdown chunks become stable outer lazy-stack rows")
    func flattenedMarkdownChunks() {
        let source = (1...3)
            .map { String($0) + String(repeating: "a", count: 699) }
            .joined(separator: "\n\n")
        let turns = [
            Turn(
                id: "turn-1",
                startedAt: Date(timeIntervalSince1970: 1_000),
                rows: [
                    .assistantMessage(
                        .text(
                            messageID: "assistant-1",
                            content: .init(source),
                            isMostRecentTextInTurn: true
                        )
                    ),
                ]
            ),
        ]
        let rows = turns.flattenedChatRows(activeTurnID: nil)

        expectNoDifference(
            rows.map(\.id),
            [
                "assistant:assistant-1:chunk:0",
                "assistant:assistant-1:chunk:1",
            ]
        )
        #expect(rows.allSatisfy {
            guard case .assistantTextChunk(_, _, let isMostRecentTextInTurn) = $0 else {
                return false
            }
            return isMostRecentTextInTurn
        })
    }

    @Test("Protocol-only events are ignored and errors become visible rows")
    func protocolEvents() throws {
        let turnID = "turn-1"
        let messages = try [
            makeStoredMessage(id: "human", role: "user", content: "Run it", turnID: turnID),
            makeEventMessage(
                id: "thinking",
                event: #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"Inspecting the implementation."}]}}"#,
                turnID: turnID
            ),
            makeEventMessage(
                id: "tool-result",
                event: #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"item_1","content":"done","is_error":false}]}}"#,
                turnID: turnID
            ),
            makeEventMessage(
                id: "system",
                event: #"{"type":"system","subtype":"status","status":"compacting"}"#,
                turnID: turnID
            ),
            makeEventMessage(
                id: "result",
                event: #"{"type":"result","usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":0}}"#,
                turnID: turnID
            ),
            makeEventMessage(
                id: "unknown-event",
                event: #"{"type":"future_event","value":42}"#,
                turnID: turnID
            ),
            makeEventMessage(
                id: "unknown-block",
                event: #"{"type":"assistant","message":{"content":[{"type":"future_block","value":42}]}}"#,
                turnID: turnID
            ),
            makeEventMessage(
                id: "error",
                event: #"{"type":"error","content":"aborted by user"}"#,
                turnID: turnID
            ),
        ]
        let startedAt = try #require(messages.first?.createdAt)

        expectNoDifference(
            Turn.parse(messages: messages).map(\.testProjection),
            [
                TurnProjection(
                    id: turnID,
                    startedAt: startedAt,
                    rows: [
                        .humanMessage(id: "human", content: "Run it"),
                        .assistantError(messageID: "error", message: "aborted by user"),
                    ]
                ),
            ]
        )
    }

    @Test("Elapsed time matches Conductor's compact turn-row format")
    @MainActor
    func elapsedTimeDescription() {
        #expect(TurnInProgressView.elapsedTimeDescription(4.29) == "4.2s")
        #expect(TurnInProgressView.elapsedTimeDescription(364.29) == "6m, 4.2s")
        #expect(TurnInProgressView.elapsedTimeDescription(5_969.29) == "99m, 29.2s")
        #expect(
            TurnInProgressView.elapsedTimeDescription(364.29, showsTenths: false)
                == "6m, 4s"
        )
    }

    @Test("The active turn gets a progress row in flattened presentation data")
    func activeTurnProgressRow() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let turns = [
            Turn(
                id: "turn-1",
                startedAt: startedAt,
                rows: [.humanMessageRow(.init(id: "human-1", content: "Hello"))]
            ),
        ]

        let activeRows = turns.flattenedChatRows(activeTurnID: "turn-1")
        expectNoDifference(activeRows.map(\.id), ["human:human-1", "turn-in-progress:turn-1"])
        guard case let .turnInProgress(progress) = activeRows.last else {
            Issue.record("Expected a turn progress row")
            return
        }
        #expect(progress.id == "turn-1")
        #expect(progress.startedAt == startedAt)

        expectNoDifference(
            turns.flattenedChatRows(activeTurnID: nil).map(\.id),
            ["human:human-1"]
        )
    }

    @Test("Every specialized tool uses its observed input shape")
    func specializedTools() throws {
        let fixtures: [(id: String, event: String, expected: ToolCall)] = [
            (
                "bash",
                #"{"type":"assistant","session_id":"019cc647-f80f-74b3-815d-9d7ec5d66392","message":{"role":"assistant","content":[{"type":"tool_use","id":"item_1","name":"Bash","input":{"command":"pwd"}}]}}"#,
                .bash(toolUseID: "item_1", command: "pwd")
            ),
            (
                "list",
                #"{"type":"assistant","session_id":"019e1984-74e6-7bf1-beb7-45f561d7b1cb","message":{"role":"assistant","content":[{"type":"tool_use","id":"call_8LaGeTsnvpxJqSXpkQ2xjPk0","name":"LS","input":{}}]}}"#,
                .listFiles(toolUseID: "call_8LaGeTsnvpxJqSXpkQ2xjPk0", path: nil)
            ),
            (
                "list-path",
                #"{"type":"assistant","session_id":"019e1984-74e6-7bf1-beb7-45f561d7b1cb","message":{"role":"assistant","content":[{"type":"tool_use","id":"call_VW9rigR9FvxKIrtCO6CYuYfI","name":"LS","input":{"path":"resources"}}]}}"#,
                .listFiles(toolUseID: "call_VW9rigR9FvxKIrtCO6CYuYfI", path: "resources")
            ),
            (
                "web-search",
                #"{"type":"assistant","session_id":"019f4d32-dab4-7e60-aaa3-ef4fc83f2a28","message":{"role":"assistant","content":[{"type":"tool_use","id":"exec-f11af96c-5de0-4a2c-802e-2218df46773f","name":"WebSearch","input":{"query":""}}]}}"#,
                .webSearch(toolUseID: "exec-f11af96c-5de0-4a2c-802e-2218df46773f")
            ),
            (
                "grep",
                #"{"type":"assistant","session_id":"019f4d32-dab4-7e60-aaa3-ef4fc83f2a28","message":{"role":"assistant","content":[{"type":"tool_use","id":"exec-d905665f-e9f0-4902-8252-d8a58db33dfa","name":"Grep","input":{"pattern":"\\$[A-Za-z0-9_]+\\.load\\(|\\.load\\(","path":"Modules"}}]}}"#,
                .grep(
                    toolUseID: "exec-d905665f-e9f0-4902-8252-d8a58db33dfa",
                    pattern: #"\$[A-Za-z0-9_]+\.load\(|\.load\("#,
                    path: "Modules"
                )
            ),
            (
                "read",
                #"{"type":"assistant","session_id":"019efccd-96d5-7660-a485-62edc418caf0","message":{"role":"assistant","content":[{"type":"tool_use","id":"call_eR6ok9AcbUteSmqL3SQZclSs","name":"Read","input":{"file_path":"/tmp/ha-core-clean.log"}}]}}"#,
                .readFile(toolUseID: "call_eR6ok9AcbUteSmqL3SQZclSs", filePath: "/tmp/ha-core-clean.log")
            ),
            (
                "write",
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"write-1","name":"Write","input":{"file_path":"Sources/String+Extensions.swift","content":"var nilIfEmpty: String? { isEmpty ? nil : self }"}}]}}"#,
                .writeFile(
                    toolUseID: "write-1",
                    filePath: "Sources/String+Extensions.swift",
                    content: "var nilIfEmpty: String? { isEmpty ? nil : self }"
                )
            ),
            (
                "edit",
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"edit-1","name":"Edit","input":{"file_path":"Tests/RepositoryTests.swift","old_string":"    }\n\n}","new_string":"    }\n}"}}]}}"#,
                .editFile(
                    toolUseID: "edit-1",
                    filePath: "Tests/RepositoryTests.swift",
                    oldString: "    }\n\n}",
                    newString: "    }\n}"
                )
            ),
            (
                "mcp",
                #"{"type":"assistant","session_id":"019f4a14-8620-78f3-8790-12226f343678","message":{"role":"assistant","content":[{"type":"tool_use","id":"exec-b47bcc51-0a63-4ab3-9915-b82736764f03","name":"mcp__XcodeBuildMCP__screenshot","input":{}}]}}"#,
                .mcp(
                    toolUseID: "exec-b47bcc51-0a63-4ab3-9915-b82736764f03",
                    name: "mcp__XcodeBuildMCP__screenshot"
                )
            ),
        ]
        let messages = try fixtures.map {
            try makeEventMessage(id: $0.id, event: $0.event, turnID: "turn-1")
        }

        expectNoDifference(
            Turn.parse(messages: messages).first?.rows.map(\.testProjection),
            fixtures.map {
                .assistantToolCall(messageID: $0.id, toolCall: $0.expected)
            }
        )
    }

    @Test("Unknown tools and malformed specialized inputs remain lossless")
    func unknownTools() throws {
        let fixtures: [(id: String, name: String, input: String, expectedInput: [String: JSONValue])] = [
            ("unknown", "TaskList", "{}", [:]),
            ("bash", "Bash", #"{"timeout":1000}"#, ["timeout": .integer(1000)]),
            ("grep", "Grep", #"{"pattern":"TODO"}"#, ["pattern": .string("TODO")]),
            ("read", "Read", "{}", [:]),
            ("write", "Write", #"{"file_path":"File.swift"}"#, ["file_path": .string("File.swift")]),
            (
                "edit",
                "Edit",
                #"{"file_path":"File.swift","old_string":"old"}"#,
                ["file_path": .string("File.swift"), "old_string": .string("old")]
            ),
        ]
        let messages = try fixtures.map { fixture in
            try makeEventMessage(
                id: fixture.id,
                event:
                    """
                    {"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-\(fixture.id)","name":"\(fixture.name)","input":\(fixture.input)}]}}
                    """,
                turnID: "turn-1"
            )
        }

        expectNoDifference(
            Turn.parse(messages: messages).first?.rows.map(\.testProjection),
            fixtures.map {
                .assistantToolCall(
                    messageID: $0.id,
                    toolCall: .unknown(
                        toolUseID: "tool-\($0.id)",
                        name: $0.name,
                        input: $0.expectedInput
                    )
                )
            }
        )
    }
}

private struct TurnProjection: Equatable {
    let id: String
    let startedAt: Date
    let rows: [TurnRowProjection]
}

private enum TurnRowProjection: Equatable {
    case humanMessage(id: String, content: String)
    case assistantText(
        messageID: String,
        renderedChunks: [String],
        isMostRecentTextInTurn: Bool
    )
    case assistantToolCall(
        messageID: String,
        toolCall: Turn.Row.AssistantMessage.ToolCall
    )
    case assistantError(messageID: String, message: String)
}

private extension Turn {
    var testProjection: TurnProjection {
        TurnProjection(
            id: id,
            startedAt: startedAt,
            rows: rows.map(\.testProjection)
        )
    }
}

private extension Turn.Row {
    var testProjection: TurnRowProjection {
        switch self {
        case .humanMessageRow(let row):
            .humanMessage(id: row.id, content: row.content)
        case .assistantMessage(let message):
            switch message {
            case let .text(messageID, content, isMostRecentTextInTurn):
                .assistantText(
                    messageID: messageID,
                    renderedChunks: content.chunks.map { $0.markdown.renderPlainText() },
                    isMostRecentTextInTurn: isMostRecentTextInTurn
                )
            case let .toolCall(messageID, toolCall):
                .assistantToolCall(messageID: messageID, toolCall: toolCall)
            case let .error(messageID, message):
                .assistantError(messageID: messageID, message: message)
            }
        }
    }
}

private typealias ToolCall = Turn.Row.AssistantMessage.ToolCall

private func makeEventMessage(id: String, event: String, turnID: String) throws -> Message {
    try makeStoredMessage(id: id, role: "assistant", content: event, turnID: turnID)
}

private func makeStoredMessage(
    id: String,
    role: String,
    content: String,
    turnID: String
) throws -> Message {
    try JSONDecoder.conductor.decode(
        Message.self,
        from: JSONEncoder().encode(
            StoredMessageFixture(id: id, role: role, content: content, turnID: turnID)
        )
    )
}

private struct StoredMessageFixture: Encodable {
    let id: String
    let role: String
    let content: String
    let turnID: String
    let sessionID = "session-1"
    let createdAt = "2026-07-10T00:00:00.000Z"

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case turnID = "turn_id"
        case sessionID = "session_id"
        case createdAt = "created_at"
    }
}

private extension TurnTests {
    static let completeTurnJSON =
        #"""
        [
          {
            "id": "42a0e1cf-2f00-47fb-9f60-e3192a155ac4",
            "session_id": "62f78383-f050-4f1b-9ca9-35d634ffe93f",
            "role": "user",
            "content": "test",
            "created_at": "2026-03-06T02:00:17.386Z",
            "sent_at": "2026-03-06T02:00:17.408Z",
            "full_message": null,
            "cancelled_at": null,
            "model": "gpt-5.3-codex",
            "sdk_message_id": null,
            "last_assistant_message_id": null,
            "turn_id": "42a0e1cf-2f00-47fb-9f60-e3192a155ac4",
            "is_resumable_message": null,
            "queue_order": null,
            "sender_id": null
          },
          {
            "id": "e84a6de0-2bce-49e6-91b8-72afa06caa81",
            "session_id": "62f78383-f050-4f1b-9ca9-35d634ffe93f",
            "role": "assistant",
            "content": "{\"type\":\"system\",\"session_id\":\"019cb186-53df-7aa0-9361-725d0c70a4fb\"}",
            "created_at": "2026-03-06T02:00:17.968Z",
            "sent_at": "2026-03-06T02:00:17.968Z",
            "turn_id": "42a0e1cf-2f00-47fb-9f60-e3192a155ac4"
          },
          {
            "id": "10d56140-7118-450e-b59d-b476803688da",
            "session_id": "62f78383-f050-4f1b-9ca9-35d634ffe93f",
            "role": "assistant",
            "content": "{\"type\":\"assistant\",\"session_id\":\"019cb186-53df-7aa0-9361-725d0c70a4fb\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Ready.\"}]}}",
            "created_at": "2026-03-06T02:00:25.628Z",
            "sent_at": "2026-03-06T02:00:25.628Z",
            "turn_id": "42a0e1cf-2f00-47fb-9f60-e3192a155ac4"
          },
          {
            "id": "bcd273ce-5341-49b3-a543-591a461e7130",
            "session_id": "62f78383-f050-4f1b-9ca9-35d634ffe93f",
            "role": "assistant",
            "content": "{\"type\":\"result\",\"session_id\":\"019cb186-53df-7aa0-9361-725d0c70a4fb\",\"usage\":{\"input_tokens\":6602250,\"output_tokens\":30335,\"cache_read_input_tokens\":6216960}}",
            "created_at": "2026-03-06T02:00:25.656Z",
            "sent_at": "2026-03-06T02:00:25.656Z",
            "turn_id": "42a0e1cf-2f00-47fb-9f60-e3192a155ac4"
          }
        ]
        """#
}
