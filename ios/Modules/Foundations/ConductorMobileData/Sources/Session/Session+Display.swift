//
//  Session+Display.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Foundation
import SharedConductorData

extension Session {
    public var displayTitle: String {
        guard let title, !title.isEmpty else {
            return "Untitled Session"
        }
        return title
    }

    public var debugSubtitle: String {
        [status.rawValue, model.rawValue, agentType.rawValue]
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }

    public var updatedDate: Date? {
        Date.conductorDate(from: updatedAt)
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

extension Session.Model {
    public var displayName: String {
        switch self {
        case .fable5:
            "Fable 5"
        case .opus:
            "Opus"
        case .opus_1M:
            "Opus 1M"
        case .opus5_1M:
            "Opus 5"
        case .opus4_8_1M:
            "Opus 4.8 1M"
        case .opus4_7_1M:
            "Opus 4.7 1M"
        case .opus4_6_1M:
            "Opus 4.6 1M"
        case .sonnet5_1M:
            "Sonnet 5 1M"
        case .sonnet_4_6_1M:
            "Sonnet 4.6 1M"
        case .sonnet_4_6:
            "Sonnet 4.6"
        case .haiku4_5:
            "Haiku 4.5"
        case .gpt_5_6_sol:
            "GPT-5.6 Sol"
        case .gpt_5_6_terra:
            "GPT-5.6 Terra"
        case .gpt_5_6_luna:
            "GPT-5.6 Luna"
        case .gpt5_5:
            "GPT-5.5"
        case .gpt5_4:
            "GPT-5.4"
        case .gpt5_3Codex:
            "GPT-5.3 Codex"
        default:
            rawValue
        }
    }

    public var fallbackContextWindowTokenLimit: Int? {
        switch self {
        case .fable5,
             .opus_1M,
             .opus5_1M,
             .opus4_8_1M,
             .opus4_7_1M,
             .opus4_6_1M,
             .sonnet5_1M,
             .sonnet_4_6_1M:
            1_000_000
        case .opus, .sonnet_4_6, .haiku4_5:
            200_000
        case .gpt_5_6_sol,
             .gpt_5_6_terra,
             .gpt_5_6_luna,
             .gpt5_5,
             .gpt5_4,
             .gpt5_3Codex:
            272_000
        default:
            nil
        }
    }
}

extension Session.ReasoningEffort {
    public var displayName: String {
        switch self {
        case .none:
            "Default"
        case .low:
            "Light"
        case .medium:
            "Medium"
        case .high:
            "High"
        case .extraHigh:
            "Extra high"
        case .max:
            "Max"
        case .ultra:
            "Ultra"
        case .ultracode:
            "Ultra"
        default:
            rawValue.capitalized
        }
    }
}
