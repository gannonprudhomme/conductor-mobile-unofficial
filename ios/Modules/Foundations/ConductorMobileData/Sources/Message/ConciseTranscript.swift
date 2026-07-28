//
//  ConciseTranscript.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/19/26.
//

import ConductorFoundation
import Foundation
import SharedConductorData

public enum ConciseTranscript {
    public static func format(_ messages: [Message]) -> String? {
        let parsedMessages = messages.map(ParsedMessage.init)
        var turnOrder: [String] = []
        var messagesByTurnID: [String: [ParsedMessage]] = [:]

        for message in parsedMessages {
            guard let turnID = message.message.turnID else {
                continue
            }
            if messagesByTurnID[turnID] == nil {
                turnOrder.append(turnID)
            }
            messagesByTurnID[turnID, default: []].append(message)
        }

        let turns = turnOrder.compactMap { turnID in
            formatTurn(messagesByTurnID[turnID, default: []])
        }
        return turns.isEmpty ? nil : turns.joined(separator: "\n\n")
    }

    private static func formatTurn(_ messages: [ParsedMessage]) -> String? {
        let visibleMessages = messages.filter { $0.message.cancelledAt == nil }
        let hasUserMessage = visibleMessages.contains {
            $0.message.role == .user
                && $0.message.content?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty != nil
        }
        guard hasUserMessage else {
            return nil
        }

        var assistantMessages = visibleMessages.filter {
            $0.message.role != .user && $0.parentToolUseID == nil
        }
        let hasCompactBoundary = assistantMessages.contains {
            $0.event?.isCompactBoundary == true
        }
        let hasCompaction = hasCompactBoundary || assistantMessages.contains {
            $0.event?.isCompactingStatus == true
        }
        assistantMessages.removeAll {
            (hasCompaction && $0.event?.isCompactedMessage == true)
                || (hasCompactBoundary && $0.event?.isCompactingStatus == true)
        }
        let assistantMessageIDs = Set(assistantMessages.map(\.message.id))
        let previewMessageIDs = previewMessageIDs(in: assistantMessages)

        var entries: [Entry] = []
        var elidedCount = 0
        func appendElision() {
            guard elidedCount > 0 else {
                return
            }
            let noun = elidedCount == 1 ? "message" : "messages"
            entries.append(
                Entry(
                    speaker: "Assistant",
                    text: "[\(elidedCount) \(noun) elided]"
                )
            )
            elidedCount = 0
        }

        for message in visibleMessages {
            if message.message.role == .user {
                guard let content = message.message.content?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ), !content.isEmpty else {
                    continue
                }
                appendElision()
                entries.append(Entry(speaker: "User", text: content.conciseSanitized))
                continue
            }

            if message.parentToolUseID != nil {
                elidedCount += 1
                continue
            }
            guard assistantMessageIDs.contains(message.message.id) else {
                continue
            }
            if previewMessageIDs.contains(message.message.id),
               let text = message.event?.conciseText {
                appendElision()
                entries.append(Entry(speaker: "Assistant", text: text))
            } else {
                elidedCount += 1
            }
        }
        appendElision()

        var sections: [String] = []
        var index = entries.startIndex
        while index < entries.endIndex {
            let speaker = entries[index].speaker
            var texts: [String] = []
            while index < entries.endIndex, entries[index].speaker == speaker {
                texts.append(String(entries[index].text.prefix(10_000)))
                index += 1
            }
            sections.append("## \(speaker)\n\n\(texts.joined(separator: "\n\n"))")
        }
        return sections.joined(separator: "\n\n")
    }

    private static func previewMessageIDs(
        in messages: [ParsedMessage]
    ) -> Set<Message.ID> {
        var groups: [[ParsedMessage]] = []
        var group: [ParsedMessage] = []
        for message in messages {
            group.append(message)
            if message.event?.isResult == true {
                groups.append(group)
                group.removeAll(keepingCapacity: true)
            }
        }
        if !group.isEmpty {
            groups.append(group)
        }

        return groups.reduce(into: Set()) { result, group in
            var hasText = false
            var shouldSuppressText = false
            var hasPreviewMessage = false

            for message in group.reversed() {
                guard let event = message.event else {
                    continue
                }
                let isError = event.isError
                let asksUser = event.toolNames.contains("AskUserQuestion")
                let exitsPlanMode = event.toolNames.contains("ExitPlanMode")
                let hasAssistantText = message.message.role == .assistant && event.hasText
                if (isError || asksUser || exitsPlanMode), !hasPreviewMessage {
                    shouldSuppressText = true
                }

                let shouldInclude = isError
                    || asksUser
                    || exitsPlanMode
                    || (hasAssistantText && !hasText && !shouldSuppressText)
                if hasAssistantText {
                    hasText = true
                }
                if shouldInclude {
                    hasPreviewMessage = true
                    result.insert(message.message.id)
                }
            }
        }
    }

    private struct Entry {
        let speaker: String
        let text: String
    }

    private struct ParsedMessage {
        let event: AgentEvent?
        let message: Message

        var parentToolUseID: String? { event?.parentToolUseID }

        init(_ message: Message) {
            self.message = message
            self.event = if message.role == .user {
                nil
            } else if let content = message.content,
                      let data = content.data(using: .utf8) {
                try? JSONDecoder().decode(AgentEvent.self, from: data)
            } else {
                nil
            }
        }
    }
}

private extension AgentEvent {
    var hasText: Bool {
        switch self {
        case .assistant(let event):
            event.message.content.contains(where: \.hasText)
        case .user(let event):
            event.message.content.contains(where: \.hasText)
        case .error, .result, .system, .unknown:
            false
        }
    }

    var toolNames: Set<String> {
        switch self {
        case .assistant(let event):
            Set(event.message.content.compactMap(\.toolName))
        case .error, .result, .system, .unknown, .user:
            []
        }
    }

    var isCompactBoundary: Bool {
        guard case .system(let event) = self else {
            return false
        }
        return event.subtype == .compactBoundary
    }

    var isCompactedMessage: Bool {
        guard case .assistant(let event) = self,
              event.message.content.count == 1 else {
            return false
        }
        return event.message.content.first?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "Compacted"
    }

    var isCompactingStatus: Bool {
        guard case .system(let event) = self else {
            return false
        }
        return event.subtype == .status && event.status == .compacting
    }

    var isError: Bool {
        switch self {
        case .error:
            true
        case .result(let event):
            event.isError
        case .assistant, .system, .unknown, .user:
            false
        }
    }

    var isResult: Bool {
        guard case .result = self else {
            return false
        }
        return true
    }

    var conciseText: String? {
        switch self {
        case .assistant(let event):
            return Self.collapse(event.message.content.compactMap(\.concisePart))
        case .user(let event):
            return Self.collapse(event.message.content.compactMap(\.concisePart))
        case .error(let event):
            let content = event.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty ?? "Unknown error"
            return "[Error: \(content)]"
        case .result(let event):
            if let result = event.result?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty {
                return "[Result: \(result)]"
            } else if event.isError, let errors = event.errors, !errors.isEmpty {
                return "[Result error: \(errors.joined(separator: "; "))]"
            } else {
                return nil
            }
        case .system(let event):
            guard let content = event.content?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty else {
                return nil
            }
            return "[System: \(content)]"
        case .unknown:
            return nil
        }
    }

    private static func collapse(_ parts: [ConcisePart]) -> String? {
        guard !parts.isEmpty else {
            return nil
        }
        var collapsed: [String] = []
        var toolCount = 0
        func appendToolCount() {
            guard toolCount > 0 else {
                return
            }
            let noun = toolCount == 1 ? "call" : "calls"
            collapsed.append("[\(toolCount) tool \(noun) elided]")
            toolCount = 0
        }
        for part in parts {
            if part.isTool {
                toolCount += 1
            } else {
                appendToolCount()
                collapsed.append(part.text)
            }
        }
        appendToolCount()
        return collapsed.joined(separator: "\n\n")
    }
}

private extension AgentEvent.AssistantEvent.AssistantMessage.AssistantMessageContent {
    var concisePart: ConcisePart? {
        switch self {
        case .text(let block):
            ConcisePart.text(block.text.conciseSanitized)
        case .toolUse:
            .tool
        case .thinking:
            nil
        case .unknown(let value):
            value.concisePart
        }
    }

    var hasText: Bool {
        text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil
    }

    var text: String? {
        switch self {
        case .text(let block):
            block.text
        case .unknown(let value) where value["type"]?.stringValue == "text":
            value["text"]?.stringValue
        case .thinking, .toolUse, .unknown:
            nil
        }
    }

    var toolName: String? {
        switch self {
        case .toolUse(let block):
            block.name
        case .unknown(let value) where value["type"]?.stringValue == "tool_use":
            value["name"]?.stringValue
        case .text, .thinking, .unknown:
            nil
        }
    }
}

private extension AgentEvent.UserEvent.UserMessage.UserMessageContent {
    var concisePart: ConcisePart? {
        switch self {
        case .toolResult:
            .tool
        case .unknown(let value):
            value.concisePart
        }
    }

    var hasText: Bool {
        guard case .unknown(let value) = self,
              value["type"]?.stringValue == "text" else {
            return false
        }
        return value["text"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty != nil
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    var concisePart: ConcisePart? {
        switch self["type"]?.stringValue {
        case "image":
            ConcisePart.text("[Image]")
        case "text":
            self["text"]?.stringValue.flatMap {
                ConcisePart.text($0.conciseSanitized)
            }
        case "tool_result", "tool_use":
            .tool
        default:
            nil
        }
    }
}

private extension JSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else {
            return nil
        }
        return value
    }
}

private struct ConcisePart {
    let isTool: Bool
    let text: String

    static let tool = Self(isTool: true, text: "")

    static func text(_ value: String) -> Self? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : Self(isTool: false, text: value)
    }
}

private extension String {
    var conciseSanitized: String {
        replacing(/@⟦([^⟧]+)⟧\(([^)\n]+)\)/) { match in
            "@\(match.1)"
        }
    }
}
