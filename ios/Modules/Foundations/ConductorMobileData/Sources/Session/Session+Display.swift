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
