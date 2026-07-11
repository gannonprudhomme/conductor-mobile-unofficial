//
//  Turn.swift
//  ConductorModules
//
//  Created by Gannon Prudomme on 7/10/26.
//

import Foundation
import ConductorData
import IssueReporting

/// This is solely a representation for UI / displaying in chat,
/// Thus it is structured in a way which plays to the strengths of a `LazyVStack`.
///
/// E.g. handling conditionals in the data layer (here) instead of in a `View`
/// For more details on what I mean, see: https://wwdc.ai/2026/321
public struct Turn: Identifiable, Equatable {
    public let id: String
    let startedAt: Date
    var rows: [Row]
    
    enum Row: Identifiable, Equatable {
        case humanMessageRow(HumanMessageRow)
        case assistantMessage(AssistantMessage)
        case turnInProgress(TurnInProgress)

        var id: String {
            switch self {
            case .humanMessageRow(let row):
                "human:\(row.id)"
            case .assistantMessage(let row):
                "assistant:\(row.id)"
            case .turnInProgress(let row):
                "turn-in-progress:\(row.id)"
            }
        }

        struct TurnInProgress: Identifiable, Equatable {
            let id: Turn.ID
            let startedAt: Date
        }
        
        struct HumanMessageRow: Identifiable, Equatable {
            let id: String
            /// Message content
            let content: String
        }
        
        enum AssistantMessage: Equatable, Identifiable {
            case text(messageID: String, content: String, isMostRecentTextInTurn: Bool)
            case toolCall(messageID: String, toolCall: ToolCall)
            case error(messageID: String, message: String)
            
            var id: String {
                switch self {
                case let .text(messageID, _, _),
                     let .toolCall(messageID, _),
                     let .error(messageID, _):
                    messageID
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
    public static func parse(messages: [Message]) -> [Turn] {
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
                                .text(messageID: message.id, content: textBlock.text, isMostRecentTextInTurn: true)
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

extension Array where Element == Turn {
    /// Flattens the turns into the single row collection consumed by `ChatRows`.
    ///
    /// The progress indicator is inserted here so each element in the lazy stack's
    /// `ForEach` always produces exactly one view, including the active turn state.
    func flattenedChatRows(activeTurnID: Turn.ID?) -> [Turn.Row] {
        flatMap { turn in
            if turn.id == activeTurnID {
                turn.rows + [
                    .turnInProgress(
                        .init(id: turn.id, startedAt: turn.startedAt)
                    ),
                ]
            } else {
                turn.rows
            }
        }
    }
}
