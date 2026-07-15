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
        case .opus4_8_1M:
            "Opus 4.8 1M"
        case .opus4_7_1M:
            "Opus 4.7 1M"
        case .opus4_6_1M:
            "Opus 4.6 1M"
        case .sonnet5_1M:
            "Sonnet 5 1M"
        case .sonnet4_6_1M:
            "Sonnet 4.6 1M"
        case .sonnet4_6:
            "Sonnet 4.6"
        case .haiku4_5:
            "Haiku 4.5"
        case .gpt5_6Sol:
            "GPT-5.6 Sol"
        case .gpt5_6Terra:
            "GPT-5.6 Terra"
        case .gpt5_6Luna:
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
}
