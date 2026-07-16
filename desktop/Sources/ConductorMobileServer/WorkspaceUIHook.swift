//
//  WorkspaceUIHook.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/14/26.
//

import Dependencies
import DependenciesMacros
import Foundation

private extension WorkspaceMutation {
    func event(workspaceID: String) throws -> String {
        let workspaceID = try Self.jsonString(workspaceID)
        let field: String = switch self {
        case .pinned(let isPinned):
            "\"pinned\":\(isPinned)"
        case .status(let value):
            "\"status\":\(try Self.jsonString(value))"
        case .unread(let isUnread):
            "\"unread\":\(isUnread)"
        }
        return "data: {\"workspaceId\":\(workspaceID),\(field)}\n\n"
    }

    // JSONEncoder escapes values even though the surrounding SSE frame is assembled directly.
    static func jsonString(_ value: String) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}
