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

/// This is solely a representation for UI / displaying in chat,
/// Thus it is structured in a way which plays to the strengths of a `LazyVStack`.
///
/// E.g. handling conditionals in the data layer (here) instead of in a `View`
/// For more details on what I mean, see: https://wwdc.ai/2026/321
struct Turn: Identifiable {
    let id: String
    let startedAt: Date
    var rows: [Row]
    
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
                /// Retained only to decide whether the next snapshot can reuse these parsed chunks.
                private let source: String
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

                struct Chunk: Identifiable {
                    let id: Int
                    let markdown: MarkdownContent
                    let spacingBefore: Spacing

                    init(id: Int, source: String, spacingBefore: Spacing) {
                        self.id = id
                        self.markdown = MarkdownContent(source)
                        self.spacingBefore = spacingBefore
                    }

                    /// The original Markdown margin that must be reconstructed before this chunk.
                    /// Splitting one Markdown document into separate lazy rows prevents MarkdownUI
                    /// from applying its normal margin across the chunk boundary.
                    enum Spacing: Equatable {
                        case none
                        case standard
                        case heading
                        case thematicBreak

                        /// Returns only the padding not already supplied by the outer lazy stack.
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
                case webSearch(toolUseID: String)
                case grep(toolUseID: String, pattern: String, path: String)
                case mcp(toolUseID: String, name: String)
                case unknown(toolUseID: String, name: String, input: [String: JSONValue])
      
                init(from toolUseBlock: CodexEvent.AssistantEvent.AssistantMessage.AssistantMessageContent.ToolUseBlock) {
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
private extension Dictionary where Key == String, Value == JSONValue { /// aka `extension [String: JSONValue} { ...`
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

        let turnRows: [(turnID: String, startedAt: Date, row: Turn.Row)] = messages.compactMap { message in
            guard let role = message.role, let content = message.content, let turnID = message.turnID else {
                reportIssue("message.content was nil for \(message)")
                return nil
            }

            let startedAt = message.sentAt ?? message.createdAt

            switch role {
            case .user:
                let row = Turn.Row.HumanMessageRow(id: message.id, content: content)

                return (turnID: turnID, startedAt: startedAt, row: Turn.Row.humanMessageRow(row))
            case .assistant:
                do {
                    let codexEvent: CodexEvent = try JSONDecoder().decode(CodexEvent.self, from: Data(content.utf8))

                    let row: Turn.Row.AssistantMessage? = switch codexEvent {
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
                            case .thinking(let thinkingBlock):
                                nil
                            case .toolUse(let toolUseBlock):
                                .toolCall(messageID: message.id, toolCall: .init(from: toolUseBlock))
                            case .unknown(let dictionary):
                                nil
                            }
                        } else {
                            nil
                        }
                    case .user(let userEvent):
                        nil
                    case .system:
                        nil
                    case .result:
                        nil
                    case .error(let errorEvent):
                        .error(messageID: message.id, message: errorEvent.content)
                    case .unknown(let dictionary):
                        nil
                    }
                    
                    guard let row else {
                        return nil
                    }

                    return (turnID: turnID, startedAt: startedAt, row: Turn.Row.assistantMessage(row))
                } catch {
                    reportIssue("Couldn't decode CodexEvent with error: \(error)")
                    return nil
                }
            default:
                return nil
            }
        }
        
        var turns: [Turn] = []
        var indexByTurnID: [String: Int] = [:]
        var mostRecentTextRowIndexByTurnID: [String: Int] = [:]

        for (turnID, startedAt, row) in turnRows {
            let turnIndex: Int
            if let index = indexByTurnID[turnID] {
                turnIndex = index
            } else {
                turnIndex = turns.count
                indexByTurnID[turnID] = turnIndex
                turns.append(Turn(id: turnID, startedAt: startedAt, rows: []))
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

/// One physical row in the outer `LazyVStack`.
///
/// `Turn.Row` preserves the logical message structure, where one assistant text message
/// owns every Markdown chunk. `DisplayedChatRow` is the flattened rendering structure: it expands
/// those chunks into separate rows so SwiftUI can create them lazily near the viewport.
enum DisplayedChatRow: Identifiable {
    case humanMessage(Turn.Row.HumanMessageRow)
    case assistantTextChunk(
        messageID: String,
        chunk: Turn.Row.AssistantMessage.TextContent.Chunk,
        isMostRecentTextInTurn: Bool
    )
    case assistantToolCall(messageID: String, toolCall: Turn.Row.AssistantMessage.ToolCall)
    case assistantError(messageID: String, message: String)
    case turnInProgress(Turn.Row.TurnInProgress)

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
        }
    }
}

enum ChatRowLayout {
    static let stackSpacing: CGFloat = 8
    static let rowTopPadding: CGFloat = 8
    static let horizontalPadding: CGFloat = 16
    static let interRowSpacing = stackSpacing + rowTopPadding
}

extension Array where Element == Turn {
    /// Flattens the turns and assistant Markdown chunks into the rows consumed by `ChatRows`.
    ///
    /// The progress indicator is inserted here so each element in the lazy stack's
    /// `ForEach` always produces exactly one view, including the active turn state.
    func flattenedChatRows(activeTurnID: Turn.ID?) -> [DisplayedChatRow] {
        flatMap { turn in
            let rows = turn.rows.flatMap { row -> [DisplayedChatRow] in
                switch row {
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

            return if turn.id == activeTurnID {
                rows + [
                    .turnInProgress(
                        .init(id: turn.id, startedAt: turn.startedAt)
                    ),
                ]
            } else {
                rows
            }
        }
    }
}
