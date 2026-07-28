//
//  Turn.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/10/26.
//

import Foundation
import SharedConductorData
import ConductorMobileData
import IssueReporting
import MarkdownUI

/// This is solely a representation for displaying chat. It is structured as stable,
/// independently renderable rows for the chat collection view.
///
/// E.g. handling conditionals in the data layer (here) instead of in a `View`
/// For more details on what I mean, see: https://wwdc.ai/2026/321
struct Turn: Identifiable {
    let id: String
    let startedAt: Date
    private(set) var finishedAt: Date? = nil
    private(set) var rows: [Row]
    
    /// The first parsed representation of a parsed ``Message``
    ///
    ///
    enum Row {
        case humanMessageRow(HumanMessageRow)
        case assistantMessage(AssistantMessage)

        struct TurnInProgress: Identifiable, Equatable {
            let id: Turn.ID
            let startedAt: Date
        }
        
        struct HumanMessageRow: Identifiable, Equatable {
            let id: String
            /// Message content
            let content: String
        }
        
        enum AssistantMessage {
            case text(messageID: String, content: TextContent, isMostRecentTextInTurn: Bool)
            case toolCall(messageID: String, toolCall: ToolCall)
            case error(messageID: String, message: String)

            /// Parsed when an assistant message's source changes, then reused by later snapshots.
            struct TextContent {
                /// The complete Markdown source, retained independently of its render chunks so
                /// copying the final message never loses content at a lazy-row boundary.
                let source: String
                let chunks: [Chunk]

                init(_ source: String) {
                    self.source = source
                    let parsedChunks = MarkdownBlockParser.calculateRenderChunks(forMarkdown: source)

                    self.chunks = parsedChunks.enumerated().map { id, chunk in
                        Chunk(
                            id: id,
                            source: chunk.source,
                            spacingBefore: Self.spacing(
                                before: id,
                                chunks: parsedChunks
                            )
                        )
                    }
                }

                /// Reuses the already-renderable chunks from the previous database snapshot
                /// when this message's Markdown source is unchanged. Each changed snapshot
                /// contains the full chat history, so reparsing every unchanged message would
                /// turn one new message into work proportional to all historical Markdown.
                /// A changed source still goes through the normal parsing initializer.
                init(_ source: String, reusing previous: Self?) {
                    if let previous, previous.source == source {
                        self = previous
                    } else {
                        self.init(source)
                    }
                }

                // Only equatable for collection view's diffable data source
                struct Chunk: Equatable, Identifiable {
                    let id: Int
                    let source: String
                    let markdown: MarkdownContent
                    let spacingBefore: Spacing

                    init(id: Int, source: String, spacingBefore: Spacing) {
                        self.id = id
                        self.source = source
                        self.markdown = MarkdownContent(source)
                        self.spacingBefore = spacingBefore
                    }

                    static func == (lhs: Self, rhs: Self) -> Bool {
                        lhs.id == rhs.id
                            && lhs.source == rhs.source
                            && lhs.spacingBefore == rhs.spacingBefore
                    }

                    /// The original Markdown margin that must be reconstructed before this chunk.
                    /// Splitting one Markdown document into separate hosted rows prevents MarkdownUI
                    /// from applying its normal margin across the chunk boundary.
                    enum Spacing: Equatable {
                        case none
                        case standard
                        case heading
                        case thematicBreak

                        /// Returns only the padding not already supplied by the chat row layout.
                        /// For example, a 1.5-em heading margin at a 16-point root font is 24 points.
                        /// If the stack already provides 16 points, this returns 8.
                        func additionalTopPadding(
                            rootFontSize: CGFloat,
                            existingSpacing: CGFloat
                        ) -> CGFloat {
                            let marginMultiplier: CGFloat = switch self {
                            case .none: 0
                            case .standard: 1
                            case .heading: 1.5
                            case .thematicBreak: 2
                            }

                            return max(
                                0,
                                (rootFontSize * marginMultiplier).rounded() - existingSpacing
                            )
                        }
                    }
                }

                // Calculate spacing for two chunks combined to each other
                private static func spacing(
                    before index: Int,
                    chunks: [MarkdownBlockParser.Chunk]
                ) -> Chunk.Spacing {
                    guard index > 0 else {
                        return .none
                    }

                    // A thematic break has MarkdownUI's largest surrounding margin (2 em).
                    // A heading starts with 1.5 em, while every other boundary uses 1 em.
                    if chunks[index].firstBlockKind == .thematicBreak || chunks[index - 1].lastBlockKind == .thematicBreak {
                        return .thematicBreak
                    } else if chunks[index].firstBlockKind == .heading {
                        return .heading
                    } else {
                        return .standard
                    }
                }
            }
            
            enum ToolCall: Equatable {
                case readFile(toolUseID: String, filePath: String)
                case writeFile(toolUseID: String, filePath: String, content: String)
                case editFile(toolUseID: String, filePath: String, oldString: String, newString: String)
                /// `nil` `filePath` is just the current directory
                case listFiles(toolUseID: String, path: String?)
                case bash(toolUseID: String, command: String)
                case runLocalCommand(
                    toolUseID: String,
                    command: String,
                    description: String?,
                    reason: String?
                )
                case webSearch(toolUseID: String)
                case grep(toolUseID: String, pattern: String, path: String)
                case mcp(toolUseID: String, name: String)
                case unknown(toolUseID: String, name: String, input: [String: JSONValue])
      
                init(from toolUseBlock: AgentEvent.AssistantEvent.AssistantMessage.AssistantMessageContent.ToolUseBlock) {
                    let (toolUseID, input) = (toolUseBlock.id, toolUseBlock.input)
                    let unknown = Self.unknown(toolUseID: toolUseID, name: toolUseBlock.name, input: toolUseBlock.input)
                    
                    switch toolUseBlock.name {
                    case "Bash":
                        guard let command = input.string(for: "command") else {
                            self = unknown
                            return
                        }
                        
                        self = .bash(toolUseID: toolUseID, command: command)
                    case "LS":
                        let path = input.string(for: "path")
                        
                        self = .listFiles(toolUseID: toolUseID, path: path)
                    case "WebSearch":
                        // TODO: I think input.query is always empty?
                        // and it gets the results from the "Web search completed for:" from the tool_result
                        
                        /*
                        guard let query = input.string(for: "query") else {
                            self = unknown
                            return
                        }
                         */
                        
                        self = .webSearch(toolUseID: toolUseID)
                        
                    case "Grep":
                        guard let pattern = input.string(for: "pattern"), let path = input.string(for: "path") else {
                            self = unknown
                            return
                        }
                        
                        self = .grep(toolUseID: toolUseID, pattern: pattern, path: path)
                        
                    case "Read":
                        guard let filePath = input.string(for: "file_path") else {
                            self = unknown
                            return
                        }
                        
                        // input will have file_path, allegedly
                        self = .readFile(toolUseID: toolUseID, filePath: filePath)
                    case "Write":
                        guard let filePath = input.string(for: "file_path"), let content = input.string(for: "content") else {
                            self = unknown
                            return
                        }
                        
                        self = .writeFile(toolUseID: toolUseID, filePath: filePath, content: content)
                        
                    case "Edit":
                        guard let filePath = input.string(for: "file_path"),
                              let oldString = input.string(for: "old_string"),
                              let newString = input.string(for: "new_string")
                        else {
                            self = unknown
                            return
                        }
                        
                        self = .editFile(toolUseID: toolUseID, filePath: filePath, oldString: oldString, newString: newString)
                        
                    case "mcp__conductor__RunLocalCommand":
                        guard let command = input.string(for: "command") else {
                            self = unknown
                            return
                        }

                        self = .runLocalCommand(
                            toolUseID: toolUseID,
                            command: command,
                            description: input.string(for: "description"),
                            reason: input.string(for: "reason")
                        )
                    case let name where name.hasPrefix("mcp__"):
                        self = .mcp(toolUseID: toolUseID, name: name)
                        
                    // case "collab__wait":
                    // case "collab_spawnAgent"
                    // case "collab__sendInput"
                    // case "collab__resumeAgent"
                    // case "collab_closeAgent"

                    default:
                        self = unknown
                    }
                }
            }
        }
    }
}

/// Helper for `ToolCall.init(from toolUseBlock:)`
private extension Dictionary where Key == String, Value == JSONValue {
    func string(for key: String) -> String? {
        guard case let .string(value) = self[key] else {
            return nil
        }
        
        return value
    }
}

extension Turn {
    // TOOD: (Probably) Want to do this in parallel if possible
    static func parse(messages: [Message]) -> [Turn] {
        parse(messages: messages, reusing: [])
    }

    /// Called immediately once we receive Messages from the host
    static func parse(
        messages: [Message],
        reusing previousTurns: [Turn]
    ) -> [Turn] {
        let reusableTextContentByMessageID: [String: Row.AssistantMessage.TextContent] =
            previousTurns.reduce(into: [:]) { result, turn in
                for row in turn.rows {
                    guard case let .assistantMessage(.text(messageID, content, _)) = row else {
                        continue
                    }

                    result[messageID] = content
                }
            }

        var turns: [Turn] = []
        var indexByTurnID: [String: Int] = [:]
        var mostRecentTextRowIndexByTurnID: [String: Int] = [:]

        for message in messages {
            guard let role = message.role, let content = message.content, let turnID = message.turnID else {
                reportIssue("message.content was nil for \(message)")
                continue
            }

            let occurredAt = message.sentAt ?? message.createdAt
            let existingTurnIndex = indexByTurnID[turnID]
            let row: Row

            switch role {
            case .user:
                if let existingTurnIndex {
                    turns[existingTurnIndex].finishedAt = nil
                }

                row = .humanMessageRow(.init(id: message.id, content: content))
            case .assistant:
                do {
                    let agentEvent: AgentEvent = try JSONDecoder().decode(AgentEvent.self, from: Data(content.utf8))

                    if case .result = agentEvent {
                        if let existingTurnIndex {
                            turns[existingTurnIndex].finishedAt = occurredAt
                        }
                        continue
                    }

                    if agentEvent.isContinuationActivity, let existingTurnIndex {
                        turns[existingTurnIndex].finishedAt = nil
                    }

                    let assistantRow: Row.AssistantMessage? = switch agentEvent {
                    case .assistant(let assistantEvent):
                        if let firstContent = assistantEvent.message.content.first {
                            switch firstContent {
                            case .text(let textBlock):
                                .text(
                                    messageID: message.id,
                                    content: .init(
                                        textBlock.text,
                                        reusing: reusableTextContentByMessageID[message.id]
                                    ),
                                    isMostRecentTextInTurn: true
                                )
                            case .toolUse(let toolUseBlock):
                                .toolCall(messageID: message.id, toolCall: .init(from: toolUseBlock))
                            case .thinking, .unknown:
                                nil
                            }
                        } else {
                            nil
                        }
                    case .error(let errorEvent):
                        .error(messageID: message.id, message: errorEvent.content)
                    case .user, .system, .unknown, .result:
                        nil
                    }

                    guard let assistantRow else {
                        continue
                    }

                    row = .assistantMessage(assistantRow)
                } catch {
                    reportIssue("Couldn't decode AgentEvent with error: \(error)")
                    continue
                }
            default:
                continue
            }

            let turnIndex: Int
            if let existingTurnIndex {
                turnIndex = existingTurnIndex
            } else {
                turnIndex = turns.count
                indexByTurnID[turnID] = turnIndex
                turns.append(Turn(id: turnID, startedAt: occurredAt, rows: []))
            }

            // Store whether each text row is the turn's most recent so rendering remains O(1),
            // even for large turns. Tool calls and errors do not affect which text is most recent.
            if case .assistantMessage(.text) = row {
                if let previousRowIndex = mostRecentTextRowIndexByTurnID[turnID],
                   case let .assistantMessage(.text(messageID, content, _)) = turns[turnIndex].rows[previousRowIndex] {
                    turns[turnIndex].rows[previousRowIndex] = .assistantMessage(
                        .text(messageID: messageID, content: content, isMostRecentTextInTurn: false)
                    )
                }

                // The row is appended below, so its index is the current row count.
                mostRecentTextRowIndexByTurnID[turnID] = turns[turnIndex].rows.count
            }

            turns[turnIndex].rows.append(row)
        }

        return turns
    }
}

private extension AgentEvent {
    /// Whether this event proves the agent resumed work after an earlier result.
    /// Continuation activity invalidates that result's completion time, while passive lifecycle
    /// and bookkeeping events can arrive afterward without reopening the turn.
    var isContinuationActivity: Bool {
        switch self {
        case .assistant, .error, .unknown:
            true
        case .system(let event):
            event.isContinuationActivity
        case .user, .result:
            false
        }
    }
}

private extension AgentEvent.SystemEvent {
    var isContinuationActivity: Bool {
        guard let subtype else {
            return true
        }

        return switch subtype {
        case .sessionStateChanged:
            state == .running
        case .thinkingTokens, .taskStarted, .taskProgress, .taskNotification, .taskUpdated:
            false
        default:
            true
        }
    }
}

/// One physical row in the chat collection view.
///
/// `Turn.Row` preserves the logical message structure, where one assistant text message owns every Markdown chunk.
/// `DisplayedChatRow` is the flattened rendering structure: it expands those chunks into separate,
/// reusable collection-view rows while retaining SwiftUI for their content.
///
/// Basically meaning: this is pretty much identical to `Turn.Row`, except that this:
/// - Splits `Turn.Row.assistantMessage` into potentially multiple Markdown rows (for performance), depending on how big it is
/// - Includes `turnSummary`, `turnInProgress`, and `turnFooter`, which are not actual `Message`s, but are derived from them.
enum DisplayedChatRow: Equatable, Identifiable {
    case humanMessage(Turn.Row.HumanMessageRow)
    case assistantTextChunk(
        messageID: String,
        chunk: Turn.Row.AssistantMessage.TextContent.Chunk,
        isMostRecentTextInTurn: Bool
    )
    case assistantToolCall(messageID: String, toolCall: Turn.Row.AssistantMessage.ToolCall)
    case assistantError(messageID: String, message: String)
    case turnInProgress(Turn.Row.TurnInProgress)
    case turnSummary(TurnSummary)
    case turnFooter(TurnFooter)

    struct TurnFooter: Equatable, Identifiable {
        let id: Turn.ID
        let elapsedTime: TimeInterval
        let copyableText: String
    }

    struct TurnSummary: Equatable, Identifiable {
        let id: String
        let isExpanded: Bool
        let toolCallCount: Int
        let messageCount: Int
        let toolIcons: [ToolIcon]

        enum ToolIcon: Hashable, Identifiable {
            case fileText
            case filePen
            case fileQuestionMark
            case terminal
            case globe
            case search
            case airplay
            case laptop

            var id: Self { self }

            init(_ toolCall: Turn.Row.AssistantMessage.ToolCall) {
                self = switch toolCall {
                case .readFile:
                    .fileText
                case .writeFile, .editFile:
                    .filePen
                case .listFiles, .unknown:
                    .fileQuestionMark
                case .bash:
                    .terminal
                case .runLocalCommand:
                    .laptop
                case .webSearch:
                    .globe
                case .grep:
                    .search
                case .mcp:
                    .airplay
                }
            }
        }
    }

    var id: String {
        switch self {
        case .humanMessage(let row):
            "human:\(row.id)"
        case let .assistantTextChunk(messageID, chunk, _):
            "assistant:\(messageID):chunk:\(chunk.id)"
        case let .assistantToolCall(messageID, _),
             let .assistantError(messageID, _):
            "assistant:\(messageID)"
        case .turnInProgress(let row):
            "turn-in-progress:\(row.id)"
        case .turnSummary(let summary):
            "summary:\(summary.id)"
        case .turnFooter(let footer):
            "turn-footer:\(footer.id)"
        }
    }
}

private extension Turn.Row {
    /// Converts this logical turn row into physical chat rows, expanding assistant text into
    /// one row per rendered Markdown chunk whenever a Markdown block is too large (>2k characters currently)
    func expandedIntoMultipleMarkdownChunkRows() -> [DisplayedChatRow] {
        switch self {
        case .humanMessageRow(let row):
            [.humanMessage(row)]
        case .assistantMessage(let message):
            switch message {
            case let .text(messageID, content, isMostRecentTextInTurn):
                content.chunks.map {
                    .assistantTextChunk(
                        messageID: messageID,
                        chunk: $0,
                        isMostRecentTextInTurn: isMostRecentTextInTurn
                    )
                }
            case let .toolCall(messageID, toolCall):
                [.assistantToolCall(messageID: messageID, toolCall: toolCall)]
            case let .error(messageID, message):
                [.assistantError(messageID: messageID, message: message)]
            }
        }
    }
}

enum ChatRowLayout {
    static let stackSpacing: CGFloat = 4
    static let horizontalPadding: CGFloat = 16
    static let interRowSpacing = stackSpacing
    static let summaryHitTargetExpansion: CGFloat = 14

    static func calculatePadding(
        for row: DisplayedChatRow,
        at index: Int,
        in rows: [DisplayedChatRow]
    ) -> (top: CGFloat, bottom: CGFloat) {
        switch row {
        case .humanMessage:
            return (12, 12)
        case .assistantTextChunk(_, let chunk, _):
            // Markdown chunks and consecutive assistant messages are separate rendered rows.
            // Look ahead so adjacent assistant text shares one outer message margin.
            let shouldCollapseBottomPadding = if index < rows.index(before: rows.endIndex) {
                switch rows[index + 1] {
                case .assistantTextChunk, .turnFooter: true
                default: false
                }
            } else {
                false
            }
            return (chunk.id == 0 ? 8 : 0, shouldCollapseBottomPadding ? 0 : 8)
        case .assistantToolCall:
            return (0, 4)
        case .turnFooter:
            return (8, 0)
        case .assistantError, .turnInProgress, .turnSummary:
            return (0, 0)
        }
    }
}

/// A physical chat row with its outer renderer spacing already resolved.
struct DisplayedChatRowWithPadding: Equatable, Identifiable {
    let content: DisplayedChatRow
    let topPadding: CGFloat
    let bottomPadding: CGFloat

    var id: DisplayedChatRow.ID { content.id }
}

extension Array where Element == Turn {
    /// Flattens the turns and assistant Markdown chunks into the rows consumed by the chat renderer.
    ///
    /// Progress and spacing are inserted here so each collection item represents exactly one
    /// hosted view, including the active turn state.
    func flattenedChatRows(
        activeTurnID: Turn.ID?,
        expandedSummaryIDs: Set<DisplayedChatRow.TurnSummary.ID> = []
    ) -> [DisplayedChatRowWithPadding] {
        flatMap { turn in
            let isActive = turn.id == activeTurnID
            let projectedRows = turn.projectedChatRows(
                isActive: isActive,
                expandedSummaryIDs: expandedSummaryIDs
            )

            let rows = if isActive {
                projectedRows + [
                    .turnInProgress(
                        .init(id: turn.id, startedAt: turn.startedAt)
                    ),
                ]
            } else if let footer = turn.completedTurnFooter() {
                projectedRows + [.turnFooter(footer)]
            } else {
                projectedRows
            }

            return rows.enumerated().map { index, row in
                let rowPadding = ChatRowLayout.calculatePadding(for: row, at: index, in: rows)
                let isFirstRowInTurn = index == rows.startIndex
                let isLastRowInTurn = index == rows.index(before: rows.endIndex)
                let completedTurnBottomPadding: CGFloat = isActive ? 0 : 12

                return DisplayedChatRowWithPadding(
                    content: row,
                    topPadding: rowPadding.top + (isFirstRowInTurn ? 12 : 0),
                    bottomPadding: rowPadding.bottom
                        + (isLastRowInTurn ? completedTurnBottomPadding : 0)
                )
            }
        }
    }
}

extension Turn {
    fileprivate func completedTurnFooter() -> DisplayedChatRow.TurnFooter? {
        guard let finishedAt else {
            return nil
        }

        for row in rows.reversed() {
            guard case let .assistantMessage(.text(_, content, _)) = row,
                  !content.source.isEmpty else {
                continue
            }

            return .init(
                id: id,
                elapsedTime: max(0, finishedAt.timeIntervalSince(startedAt)),
                copyableText: content.source
            )
        }

        return nil
    }

    /// Projects this turn's logical message rows into physical chat rows.
    ///
    /// `flattenedChatRows(activeTurnID:expandedSummaryIDs:)` calls this whenever `Chat.State`
    /// rebuilds its cached presentation rows. Active turns remain fully expanded so streaming
    /// progress never disappears behind a disclosure. Completed turns are split into segments
    /// beginning with each human message; collapsible assistant work in each segment is replaced
    /// by a summary row while the last global text or error remains visible as the final response.
    ///
    /// - Parameters:
    ///   - isActive: Whether this turn is currently receiving assistant events.
    ///   - expandedSummaryIDs: Summary IDs whose assistant work should be visible.
    /// - Returns: Physical rows for the current disclosure state, ordered by source segment.
    fileprivate func projectedChatRows(
        isActive: Bool,
        expandedSummaryIDs: Set<DisplayedChatRow.TurnSummary.ID>
    ) -> [DisplayedChatRow] {
        // This turn is active, don't attempt to collapse it - just return the rows entirely
        guard !isActive else {
            return rows.flatMap { $0.expandedIntoMultipleMarkdownChunkRows() }
        }

        // A completed turn can finish with another tool call after already presenting its answer.
        // Find the last displayable text or error once for the entire turn so every segment can
        // preserve that global response without repeatedly scanning `rows`.
        let finalResponseRowIndex = rows.indices.last { index in
            switch rows[index] {
            case let .assistantMessage(.text(_, content, _)):
                !content.chunks.isEmpty
            case .assistantMessage(.error):
                true
            case .humanMessageRow, .assistantMessage(.toolCall):
                false
            }
        }
        var displayedRows: [DisplayedChatRow] = []
        var humanMessage: Row.HumanMessageRow?
        var assistantRows: [(index: Int, row: Row)] = []

        // Each human message starts a collapsible segment containing the assistant rows that follow it.
        // Assistant rows before any human message are emitted directly because they have no human anchor from which to derive a stable summary ID.
        for (index, row) in rows.enumerated() {
            switch row {
            case .humanMessageRow(let row):
                let rowsToAppend = Self.displayedRowsForSegment(
                    turnID: self.id,
                    humanMessage: humanMessage,
                    finalResponseRowIndex: finalResponseRowIndex,
                    expandedSummaryIDs: expandedSummaryIDs,
                    assistantRows: assistantRows
                )

                displayedRows.append(contentsOf: rowsToAppend)
                humanMessage = row
                assistantRows.removeAll(keepingCapacity: true)
            case .assistantMessage:
                if humanMessage == nil { // no human message before this (somehow)
                    displayedRows.append(contentsOf: row.expandedIntoMultipleMarkdownChunkRows())
                } else {
                    assistantRows.append((index, row))
                }
            }
        }

        // A segment is emitted when the next human message begins. For [human, tool, text], no next
        // human message arrives, so `humanMessage` and `assistantRows` still hold that entire
        // segment when the loop ends. Emit the final buffered segment here.
        displayedRows.append(
            contentsOf: Self.displayedRowsForSegment(
                turnID: self.id,
                humanMessage: humanMessage,
                finalResponseRowIndex: finalResponseRowIndex,
                expandedSummaryIDs: expandedSummaryIDs,
                assistantRows: assistantRows
            )
        )

        return displayedRows
    }

    /// Projects a human-message segment into physical chat rows.
    /// Keeping logical assistant rows until this point lets the summary count messages and tools
    /// before chunk expansion.
    private static func displayedRowsForSegment(
        turnID: Turn.ID,
        humanMessage: Row.HumanMessageRow?,
        finalResponseRowIndex: Int?,
        expandedSummaryIDs: Set<DisplayedChatRow.TurnSummary.ID>,
        assistantRows: [(index: Int, row: Row)]
    ) -> [DisplayedChatRow] {
        guard let humanMessage else {
            return []
        }

        // Human messages are segment anchors and always remain visible.
        var segmentRows: [DisplayedChatRow] = [.humanMessage(humanMessage)]

        // The final global response stays outside its summary. Earlier displayable text,
        // errors, and tool calls are revealable; empty text is not collapsible because toggling
        // it could not reveal a physical row.
        func shouldBeControlledByTurnSummary(_ indexedRow: (index: Int, row: Row)) -> Bool {
            guard indexedRow.index != finalResponseRowIndex else {
                return false
            }

            return switch indexedRow.row {
            case let .assistantMessage(.text(_, content, _)):
                !content.chunks.isEmpty
            case .assistantMessage(.toolCall), .assistantMessage(.error):
                true
            case .humanMessageRow:
                false
            }
        }

        let summarizedRows = assistantRows.filter(shouldBeControlledByTurnSummary)
        // A disclosure is useful only when expanding it reveals at least one row.
        guard !summarizedRows.isEmpty else {
            segmentRows.append(
                contentsOf: assistantRows.flatMap { $0.row.expandedIntoMultipleMarkdownChunkRows() }
            )
            return segmentRows
        }

        let summary = Self.turnSummaryForSegment(
            turnID: turnID,
            humanMessageID: humanMessage.id,
            expandedSummaryIDs: expandedSummaryIDs,
            assistantRows: assistantRows
        )
        segmentRows.append(.turnSummary(summary))

        // Expansion restores every displayable assistant row in source order. Collapsing retains
        // only rows excluded from the summary, principally the final global response.
        let visibleAssistantRows = if summary.isExpanded {
            assistantRows
        } else {
            assistantRows.filter { !shouldBeControlledByTurnSummary($0) }
        }

        segmentRows.append(
            contentsOf: visibleAssistantRows.flatMap { $0.row.expandedIntoMultipleMarkdownChunkRows() }
        )

        return segmentRows
    }

    /// Creates the disclosure summary for a human-message segment.
    private static func turnSummaryForSegment(
        turnID: Turn.ID,
        humanMessageID: Row.HumanMessageRow.ID,
        expandedSummaryIDs: Set<DisplayedChatRow.TurnSummary.ID>,
        assistantRows: [(index: Int, row: Row)]
    ) -> DisplayedChatRow.TurnSummary {
        // Including the human-message ID keeps summaries independently addressable when one
        // stored turn contains multiple steered human messages.
        let summaryID = "\(turnID):\(humanMessageID)"
        var messageCount = 0
        var toolCallCount = 0
        var toolIcons: [DisplayedChatRow.TurnSummary.ToolIcon] = []
        var seenToolIcons: Set<DisplayedChatRow.TurnSummary.ToolIcon> = []

        // Counts describe the complete segment, including the final response that remains visible
        // outside the disclosure. Tool icons represent distinct categories and retain first-use
        // order so their arrangement is stable and meaningful.
        for (_, row) in assistantRows {
            switch row {
            case let .assistantMessage(.text(_, content, _)):
                if !content.chunks.isEmpty {
                    messageCount += 1
                }
            case .assistantMessage(.error):
                messageCount += 1
            case .assistantMessage(.toolCall(_, let toolCall)):
                toolCallCount += 1
                let toolIcon = DisplayedChatRow.TurnSummary.ToolIcon(toolCall)
                if seenToolIcons.insert(toolIcon).inserted {
                    toolIcons.append(toolIcon)
                }
            case .humanMessageRow:
                break
            }
        }

        return .init(
            id: summaryID,
            isExpanded: expandedSummaryIDs.contains(summaryID),
            toolCallCount: toolCallCount,
            messageCount: messageCount,
            toolIcons: toolIcons
        )
    }
}
