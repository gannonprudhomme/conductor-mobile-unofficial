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
        let finishedAt = try #require(messages.last?.sentAt)
        let turns = Turn.parse(messages: messages)

        #expect(try #require(turns.first).finishedAt == finishedAt)

        expectNoDifference(
            turns.map(\.testProjection),
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
                $0.additionalTopPadding(
                    rootFontSize: 16,
                    existingSpacing: ChatRowLayout.interRowSpacing
                )
            },
            [0, 12, 20, 28]
        )
    }

    @Test("Assistant Markdown chunks become stable collection-view rows")
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
            rows.map(DisplayedRowWithPaddingProjection.init),
            [
                .init(
                    id: "assistant:assistant-1:chunk:0",
                    topPadding: 20,
                    bottomPadding: 0
                ),
                .init(
                    id: "assistant:assistant-1:chunk:1",
                    topPadding: 0,
                    bottomPadding: 20
                ),
            ]
        )
        #expect(rows.allSatisfy {
            guard case .assistantTextChunk(_, _, let isMostRecentTextInTurn) = $0.content else {
                return false
            }
            return isMostRecentTextInTurn
        })
    }

    @Test("Consecutive assistant messages share one outer margin")
    func consecutiveAssistantMessageSpacing() {
        let turns = [
            Turn(
                id: "turn-1",
                startedAt: Date(timeIntervalSince1970: 1_000),
                rows: [
                    .assistantMessage(
                        .text(
                            messageID: "assistant-1",
                            content: .init("First"),
                            isMostRecentTextInTurn: false
                        )
                    ),
                    .assistantMessage(
                        .text(
                            messageID: "assistant-2",
                            content: .init("Second"),
                            isMostRecentTextInTurn: true
                        )
                    ),
                ]
            ),
        ]

        expectNoDifference(
            turns
                .flattenedChatRows(activeTurnID: nil)
                .map(DisplayedRowWithPaddingProjection.init),
            [
                .init(
                    id: "assistant:assistant-1:chunk:0",
                    topPadding: 20,
                    bottomPadding: 0
                ),
                .init(
                    id: "assistant:assistant-2:chunk:0",
                    topPadding: 8,
                    bottomPadding: 20
                ),
            ]
        )
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

    @Test("Flattened presentation data adds row spacing and active progress")
    func activeTurnProgressRow() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let turns = [
            Turn(
                id: "turn-1",
                startedAt: startedAt,
                rows: [
                    .humanMessageRow(.init(id: "human-1", content: "Hello")),
                    .assistantMessage(
                        .text(
                            messageID: "text-1",
                            content: .init("Hi"),
                            isMostRecentTextInTurn: true
                        )
                    ),
                    .assistantMessage(
                        .toolCall(
                            messageID: "tool-1",
                            toolCall: .webSearch(toolUseID: "tool-use-1")
                        )
                    ),
                ]
            ),
        ]

        let activeRows = turns.flattenedChatRows(activeTurnID: "turn-1")
        expectNoDifference(
            activeRows.map(DisplayedRowWithPaddingProjection.init),
            [
                .init(id: "human:human-1", topPadding: 24, bottomPadding: 12),
                .init(id: "assistant:text-1:chunk:0", topPadding: 8, bottomPadding: 8),
                .init(id: "assistant:tool-1", topPadding: 0, bottomPadding: 4),
                .init(id: "turn-in-progress:turn-1", topPadding: 0, bottomPadding: 0),
            ]
        )
        guard case let .turnInProgress(progress) = activeRows.last?.content else {
            Issue.record("Expected a turn progress row")
            return
        }
        #expect(progress.id == "turn-1")
        #expect(progress.startedAt == startedAt)

        expectNoDifference(
            turns
                .flattenedChatRows(
                    activeTurnID: nil,
                    expandedSummaryIDs: ["turn-1:human-1"]
                )
                .map(DisplayedRowWithPaddingProjection.init),
            [
                .init(id: "human:human-1", topPadding: 24, bottomPadding: 12),
                .init(id: "summary:turn-1:human-1", topPadding: 0, bottomPadding: 0),
                .init(id: "assistant:text-1:chunk:0", topPadding: 8, bottomPadding: 8),
                .init(id: "assistant:tool-1", topPadding: 0, bottomPadding: 16),
            ]
        )
    }

    @Test("Completed turn footer copies the full final message across Markdown chunks")
    func completedTurnFooter() throws {
        let source = (1...3)
            .map { "## Section \($0)\n\n" + String(repeating: "a", count: 700) }
            .joined(separator: "\n\n")
        let turn = Turn(
            id: "turn-1",
            startedAt: Date(timeIntervalSince1970: 1_000),
            finishedAt: Date(timeIntervalSince1970: 1_024),
            rows: [
                .assistantMessage(
                    .text(
                        messageID: "final",
                        content: .init(source),
                        isMostRecentTextInTurn: true
                    )
                ),
            ]
        )
        let rows = [turn].flattenedChatRows(activeTurnID: nil)
        let footerRow = try #require(rows.last)
        let finalMessageRow = try #require(rows.dropLast().last)
        guard case let .turnFooter(footer) = footerRow.content else {
            Issue.record("Expected a completed turn footer")
            return
        }

        #expect(rows.dropLast().count > 1)
        #expect(finalMessageRow.bottomPadding == 0)
        #expect(footerRow.topPadding == 8)
        #expect(footerRow.bottomPadding == 12)
        #expect(footer.id == turn.id)
        #expect(footer.elapsedTime == 24)
        #expect(footer.copyableText == source)
    }

    @Test("Completed turns derive independently expandable segments in source order")
    func completedTurnProjection() {
        let human1 = Turn.Row.humanMessageRow(.init(id: "human-1", content: "Build it"))
        let text1 = Turn.Row.assistantMessage(
            .text(
                messageID: "text-1",
                content: .init("Working"),
                isMostRecentTextInTurn: false
            )
        )
        let tool1 = Turn.Row.assistantMessage(
            .toolCall(
                messageID: "tool-1",
                toolCall: .readFile(toolUseID: "tool-read", filePath: "File.swift")
            )
        )
        let human2 = Turn.Row.humanMessageRow(.init(id: "human-2", content: "Also test it"))
        let text2 = Turn.Row.assistantMessage(
            .text(
                messageID: "text-2",
                content: .init("Testing"),
                isMostRecentTextInTurn: false
            )
        )
        let tool2 = Turn.Row.assistantMessage(
            .toolCall(
                messageID: "tool-2",
                toolCall: .grep(toolUseID: "tool-grep", pattern: "projectedChatRows", path: "Tests")
            )
        )
        let final = Turn.Row.assistantMessage(
            .text(
                messageID: "final",
                content: .init("Done"),
                isMostRecentTextInTurn: true
            )
        )
        let turn = Turn(
            id: "turn-1",
            startedAt: Date(timeIntervalSince1970: 1_000),
            rows: [human1, text1, tool1, human2, text2, tool2, final]
        )
        let summary1 = DisplayedChatRow.TurnSummary(
            id: "turn-1:human-1",
            isExpanded: false,
            toolCallCount: 1,
            messageCount: 1,
            toolIcons: [.fileText]
        )
        let summary2 = DisplayedChatRow.TurnSummary(
            id: "turn-1:human-2",
            isExpanded: false,
            toolCallCount: 1,
            messageCount: 1,
            toolIcons: [.search]
        )
        let expandedSummary1 = DisplayedChatRow.TurnSummary(
            id: summary1.id,
            isExpanded: true,
            toolCallCount: summary1.toolCallCount,
            messageCount: summary1.messageCount,
            toolIcons: summary1.toolIcons
        )
        let expandedSummary2 = DisplayedChatRow.TurnSummary(
            id: summary2.id,
            isExpanded: true,
            toolCallCount: summary2.toolCallCount,
            messageCount: summary2.messageCount,
            toolIcons: summary2.toolIcons
        )
        let rows: (Set<DisplayedChatRow.TurnSummary.ID>) -> [DisplayedRowProjection] = {
            [turn]
                .flattenedChatRows(activeTurnID: nil, expandedSummaryIDs: $0)
                .map(DisplayedRowProjection.init)
        }

        expectNoDifference(
            rows([]),
            [
                .human(id: "human-1"),
                .summary(rowID: "summary:turn-1:human-1", summary: summary1),
                .human(id: "human-2"),
                .summary(rowID: "summary:turn-1:human-2", summary: summary2),
                .assistant(id: "assistant:final:chunk:0"),
            ]
        )
        expectNoDifference(
            rows([summary1.id]),
            [
                .human(id: "human-1"),
                .summary(rowID: "summary:turn-1:human-1", summary: expandedSummary1),
                .assistant(id: "assistant:text-1:chunk:0"),
                .assistant(id: "assistant:tool-1"),
                .human(id: "human-2"),
                .summary(rowID: "summary:turn-1:human-2", summary: summary2),
                .assistant(id: "assistant:final:chunk:0"),
            ]
        )
        expectNoDifference(
            rows([summary2.id]),
            [
                .human(id: "human-1"),
                .summary(rowID: "summary:turn-1:human-1", summary: summary1),
                .human(id: "human-2"),
                .summary(rowID: "summary:turn-1:human-2", summary: expandedSummary2),
                .assistant(id: "assistant:text-2:chunk:0"),
                .assistant(id: "assistant:tool-2"),
                .assistant(id: "assistant:final:chunk:0"),
            ]
        )
        expectNoDifference(
            rows([summary1.id, summary2.id]),
            [
                .human(id: "human-1"),
                .summary(rowID: "summary:turn-1:human-1", summary: expandedSummary1),
                .assistant(id: "assistant:text-1:chunk:0"),
                .assistant(id: "assistant:tool-1"),
                .human(id: "human-2"),
                .summary(rowID: "summary:turn-1:human-2", summary: expandedSummary2),
                .assistant(id: "assistant:text-2:chunk:0"),
                .assistant(id: "assistant:tool-2"),
                .assistant(id: "assistant:final:chunk:0"),
            ]
        )
    }

    @Test("Last text remains visible when followed by a tool call")
    func trailingToolCall() {
        let turn = Turn(
            id: "turn",
            startedAt: Date(timeIntervalSince1970: 1_000),
            rows: [
                .humanMessageRow(.init(id: "human", content: "Inspect it")),
                .assistantMessage(
                    .text(
                        messageID: "text",
                        content: .init("Still working"),
                        isMostRecentTextInTurn: true
                    )
                ),
                .assistantMessage(
                    .toolCall(
                        messageID: "tool",
                        toolCall: .readFile(toolUseID: "tool", filePath: "File.swift")
                    )
                ),
            ]
        )
        let summaryID = "turn:human"
        let summary = DisplayedChatRow.TurnSummary(
            id: summaryID,
            isExpanded: false,
            toolCallCount: 1,
            messageCount: 0,
            toolIcons: [.fileText]
        )
        let expandedSummary = DisplayedChatRow.TurnSummary(
            id: summaryID,
            isExpanded: true,
            toolCallCount: 1,
            messageCount: 0,
            toolIcons: [.fileText]
        )

        expectNoDifference(
            [turn]
                .flattenedChatRows(activeTurnID: nil)
                .map(DisplayedRowProjection.init),
            [
                .human(id: "human"),
                .summary(rowID: "summary:turn:human", summary: summary),
                .assistant(id: "assistant:text:chunk:0"),
            ]
        )
        expectNoDifference(
            [turn]
                .flattenedChatRows(
                    activeTurnID: nil,
                    expandedSummaryIDs: [summaryID]
                )
                .map(DisplayedRowProjection.init),
            [
                .human(id: "human"),
                .summary(rowID: "summary:turn:human", summary: expandedSummary),
                .assistant(id: "assistant:text:chunk:0"),
                .assistant(id: "assistant:tool"),
            ]
        )
    }

    @Test("Active turns stay fully visible after historical results")
    func activeTurnAfterHistoricalResults() throws {
        let turnID = "active"
        let messages = try [
            makeStoredMessage(id: "human", role: "user", content: "Hello", turnID: turnID),
            makeEventMessage(
                id: "first",
                event: #"{"type":"assistant","message":{"content":[{"type":"text","text":"First response"}]}}"#,
                turnID: turnID
            ),
            makeEventMessage(
                id: "first-result",
                event: #"{"type":"result","usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":0}}"#,
                turnID: turnID
            ),
            makeEventMessage(
                id: "continuation",
                event: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Steered continuation"}]}}"#,
                turnID: turnID
            ),
            makeEventMessage(
                id: "second-result",
                event: #"{"type":"result","usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":0}}"#,
                turnID: turnID
            ),
        ]
        let turns = Turn.parse(messages: messages)

        expectNoDifference(
            turns.flattenedChatRows(activeTurnID: turnID).map(\.id),
            [
                "human:human",
                "assistant:first:chunk:0",
                "assistant:continuation:chunk:0",
                "turn-in-progress:active",
            ]
        )
        expectNoDifference(
            turns.flattenedChatRows(activeTurnID: nil).map(\.id),
            [
                "human:human",
                "summary:active:human",
                "assistant:continuation:chunk:0",
                "turn-footer:active",
            ]
        )
    }

    @Test("A continuation interrupted after an earlier result has no footer")
    func interruptedContinuation() throws {
        let turnID = "interrupted"
        let messages = try [
            makeStoredMessage(id: "human", role: "user", content: "Start", turnID: turnID),
            makeEventMessage(
                id: "first",
                event: #"{"type":"assistant","message":{"content":[{"type":"text","text":"First response"}]}}"#,
                turnID: turnID
            ),
            makeEventMessage(
                id: "result",
                event: #"{"type":"result","usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":0}}"#,
                turnID: turnID
            ),
            makeEventMessage(
                id: "continuation",
                event: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Still working"}]}}"#,
                turnID: turnID
            ),
        ]
        let turns = Turn.parse(messages: messages)

        #expect(try #require(turns.first).finishedAt == nil)
        #expect(
            !turns.flattenedChatRows(activeTurnID: nil)
                .map(\.id)
                .contains("turn-footer:\(turnID)")
        )
    }

    @Test("An idle system event after a result preserves the completed footer")
    func idleSystemEventAfterResult() throws {
        try expectCompletedFooter(
            after: #"{"type":"system","subtype":"session_state_changed","state":"idle"}"#,
            eventID: "idle"
        )
    }

    @Test("A tool result after a result preserves the completed footer")
    func toolResultAfterResult() throws {
        try expectCompletedFooter(
            after: #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"item_1","content":"done","is_error":false}]}}"#,
            eventID: "tool-result"
        )
    }

    private func expectCompletedFooter(after event: String, eventID: String) throws {
        let turnID = "completed"
        let messages = try [
            makeStoredMessage(id: "human", role: "user", content: "Finish", turnID: turnID),
            makeEventMessage(
                id: "assistant",
                event: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Final response"}]}}"#,
                turnID: turnID
            ),
            makeEventMessage(
                id: "result",
                event: #"{"type":"result","usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":0}}"#,
                turnID: turnID
            ),
            makeEventMessage(id: eventID, event: event, turnID: turnID),
        ]
        let footerRow = try #require(
            Turn.parse(messages: messages)
                .flattenedChatRows(activeTurnID: nil)
                .last
        )
        guard case let .turnFooter(footer) = footerRow.content else {
            Issue.record("Expected a completed turn footer")
            return
        }

        expectNoDifference(
            footer,
            .init(id: turnID, elapsedTime: 0, copyableText: "Final response")
        )
    }

    @Test("Idle error-ended turns collapse without a result event")
    func idleErrorEndedTurn() throws {
        let turnID = "error-ended"
        let messages = try [
            makeStoredMessage(id: "human", role: "user", content: "Run it", turnID: turnID),
            makeEventMessage(
                id: "working",
                event: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Working"}]}}"#,
                turnID: turnID
            ),
            makeEventMessage(
                id: "tool",
                event: #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-1","name":"Read","input":{"file_path":"File.swift"}}]}}"#,
                turnID: turnID
            ),
            makeEventMessage(
                id: "error",
                event: #"{"type":"error","content":"aborted by user"}"#,
                turnID: turnID
            ),
        ]
        let summary = DisplayedChatRow.TurnSummary(
            id: "error-ended:human",
            isExpanded: false,
            toolCallCount: 1,
            messageCount: 1,
            toolIcons: [.fileText]
        )

        expectNoDifference(
            Turn.parse(messages: messages)
                .flattenedChatRows(activeTurnID: nil)
                .map(DisplayedRowProjection.init),
            [
                .human(id: "human"),
                .summary(rowID: "summary:error-ended:human", summary: summary),
                .assistant(id: "assistant:error"),
            ]
        )
    }

    @Test("Empty text does not create an empty summary")
    func segmentWithoutCollapsedContent() {
        let turn = Turn(
            id: "complete",
            startedAt: Date(timeIntervalSince1970: 1_000),
            rows: [
                .humanMessageRow(.init(id: "human", content: "Hello")),
                .assistantMessage(
                    .text(
                        messageID: "empty",
                        content: .init(""),
                        isMostRecentTextInTurn: false
                    )
                ),
                .assistantMessage(
                    .text(
                        messageID: "final",
                        content: .init("Done"),
                        isMostRecentTextInTurn: true
                    )
                ),
                .assistantMessage(
                    .text(
                        messageID: "trailing-empty",
                        content: .init(""),
                        isMostRecentTextInTurn: false
                    )
                ),
            ]
        )

        expectNoDifference(
            [turn].flattenedChatRows(activeTurnID: nil).map(\.id),
            ["human:human", "assistant:final:chunk:0"]
        )
    }

    @Test("Only the last global error remains visible and earlier errors count as messages")
    func intermediateErrors() {
        let turn = Turn(
            id: "turn",
            startedAt: Date(timeIntervalSince1970: 1_000),
            rows: [
                .humanMessageRow(.init(id: "human", content: "Try it")),
                .assistantMessage(.error(messageID: "first-error", message: "Retrying")),
                .assistantMessage(.error(messageID: "final-error", message: "Stopped")),
                .assistantMessage(
                    .toolCall(
                        messageID: "tool",
                        toolCall: .bash(toolUseID: "tool", command: "swift test")
                    )
                ),
            ]
        )
        let summaryID = "turn:human"
        let summary = DisplayedChatRow.TurnSummary(
            id: summaryID,
            isExpanded: false,
            toolCallCount: 1,
            messageCount: 1,
            toolIcons: [.terminal]
        )
        let expandedSummary = DisplayedChatRow.TurnSummary(
            id: summaryID,
            isExpanded: true,
            toolCallCount: 1,
            messageCount: 1,
            toolIcons: [.terminal]
        )

        expectNoDifference(
            [turn]
                .flattenedChatRows(activeTurnID: nil)
                .map(DisplayedRowProjection.init),
            [
                .human(id: "human"),
                .summary(rowID: "summary:turn:human", summary: summary),
                .assistant(id: "assistant:final-error"),
            ]
        )
        expectNoDifference(
            [turn]
                .flattenedChatRows(
                    activeTurnID: nil,
                    expandedSummaryIDs: [summaryID]
                )
                .map(DisplayedRowProjection.init),
            [
                .human(id: "human"),
                .summary(rowID: "summary:turn:human", summary: expandedSummary),
                .assistant(id: "assistant:first-error"),
                .assistant(id: "assistant:final-error"),
                .assistant(id: "assistant:tool"),
            ]
        )
    }

    @Test("Summary tool icons are ordered and distinct")
    func summaryToolIcons() throws {
        let turn = Turn(
            id: "turn",
            startedAt: Date(timeIntervalSince1970: 1_000),
            rows: [
                .humanMessageRow(.init(id: "human", content: "Inspect it")),
                .assistantMessage(
                    .toolCall(
                        messageID: "read-1",
                        toolCall: .readFile(toolUseID: "read-1", filePath: "One.swift")
                    )
                ),
                .assistantMessage(
                    .toolCall(
                        messageID: "write",
                        toolCall: .writeFile(toolUseID: "write", filePath: "Two.swift", content: "")
                    )
                ),
                .assistantMessage(
                    .toolCall(
                        messageID: "read-2",
                        toolCall: .readFile(toolUseID: "read-2", filePath: "Three.swift")
                    )
                ),
                .assistantMessage(.error(messageID: "error", message: "Recovered")),
                .assistantMessage(
                    .text(
                        messageID: "final",
                        content: .init("Done"),
                        isMostRecentTextInTurn: true
                    )
                ),
            ]
        )
        let displayedRows = [turn].flattenedChatRows(activeTurnID: nil)
        let summaries: [DisplayedChatRow.TurnSummary] = displayedRows
            .compactMap { row in
                guard case .turnSummary(let summary) = row.content else {
                    return nil
                }
                return summary
            }
        let summary = try #require(summaries.first)

        expectNoDifference(
            displayedRows.map(\.id),
            ["human:human", "summary:turn:human", "assistant:final:chunk:0"]
        )
        #expect(summary.toolCallCount == 3)
        #expect(summary.messageCount == 1)
        expectNoDifference(summary.toolIcons, [.fileText, .filePen])
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

private enum DisplayedRowProjection: Equatable {
    case human(id: String)
    case assistant(id: String)
    case turnInProgress(id: String)
    case summary(rowID: String, summary: DisplayedChatRow.TurnSummary)
    case footer(DisplayedChatRow.TurnFooter)

    init(_ row: DisplayedChatRowWithPadding) {
        self.init(row.content)
    }

    init(_ row: DisplayedChatRow) {
        self = switch row {
        case .humanMessage(let message):
            .human(id: message.id)
        case .assistantTextChunk, .assistantToolCall, .assistantError:
            .assistant(id: row.id)
        case .turnInProgress(let progress):
            .turnInProgress(id: progress.id)
        case .turnSummary(let summary):
            .summary(rowID: row.id, summary: summary)
        case .turnFooter(let footer):
            .footer(footer)
        }
    }
}

private struct DisplayedRowWithPaddingProjection: Equatable {
    let id: String
    let topPadding: CGFloat
    let bottomPadding: CGFloat

    init(_ row: DisplayedChatRowWithPadding) {
        self.id = row.id
        self.topPadding = row.topPadding
        self.bottomPadding = row.bottomPadding
    }

    init(id: String, topPadding: CGFloat, bottomPadding: CGFloat) {
        self.id = id
        self.topPadding = topPadding
        self.bottomPadding = bottomPadding
    }
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
