//
//  Session+Display.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import Foundation

extension Session {
    public var displayTitle: String {
        title.isEmpty ? "Untitled Session" : title
    }

    public var debugSubtitle: String {
        [status.rawValue, model, agentType.rawValue]
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }

    public var updatedDate: Date? {
        Date.conductorDate(from: updatedAt)
    }

    public var displayModelName: String {
        switch model {
        case "gpt-5.3-codex":
            "GPT-5.3 Codex"
        case "gpt-5.4":
            "GPT-5.4"
        case "gpt-5.5":
            "GPT-5.5"
        case "gpt-5.6-sol":
            "GPT-5.6 Sol"
        case "fable-5":
            "Fable 5"
        case "opus":
            "Opus"
        case "opus-1m":
            "Opus 1M"
        case "opus-4-8-1m":
            "Opus 4.8 1M"
        case "sonnet":
            "Sonnet"
        default:
            model
        }
    }

    public var availableReasoningEfforts: [ReasoningEffort] {
        switch agentType {
        case .codex:
            if model == "gpt-5.6-sol" {
                [.low, .medium, .high, .extraHigh, .max, .ultra]
            } else {
                [.low, .medium, .high, .extraHigh]
            }
        case .claude:
            if claudeEffortLevel == nil {
                []
            } else {
                [.low, .medium, .high, .extraHigh]
            }
        default:
            []
        }
    }

    public func nextReasoningEffort(after currentEffort: ReasoningEffort) -> ReasoningEffort? {
        let efforts = availableReasoningEfforts
        guard let firstEffort = efforts.first else {
            return nil
        }
        guard let currentIndex = efforts.firstIndex(of: currentEffort) else {
            return firstEffort
        }

        let nextIndex = efforts.index(after: currentIndex)
        return nextIndex == efforts.endIndex ? firstEffort : efforts[nextIndex]
    }
}

extension Session.AgentType {
    public var displayName: String {
        switch self {
        case .codex:
            "Codex"
        case .claude:
            "Claude"
        default:
            rawValue
        }
    }
}

extension Session.ReasoningEffort {
    public func displayName(agentType: Session.AgentType) -> String {
        switch self {
        case .none:
            "Default"
        case .low:
            "Low"
        case .medium:
            "Medium"
        case .high:
            "High"
        case .extraHigh:
            agentType == .claude ? "Max" : "Extra high"
        case .max:
            "Max"
        case .ultra:
            "Ultra"
        default:
            rawValue.capitalized
        }
    }
}
