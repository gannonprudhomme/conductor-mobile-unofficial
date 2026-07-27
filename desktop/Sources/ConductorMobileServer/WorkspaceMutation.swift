//
//  WorkspaceMutation.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/15/26.
//

enum WorkspaceMutation: Equatable, Sendable {
    case archive
    case branch(String)
    case pinned(isPinned: Bool)
    case status(String)
    case unread(isUnread: Bool)
}

enum SessionMutation: Equatable, Sendable {
    case hidden(isHidden: Bool)
    case title(String)
}

enum UIHookCommand: Equatable, Sendable {
    case session(id: String, workspaceID: String, mutation: SessionMutation)
    case workspace(id: String, mutation: WorkspaceMutation)
    case sessionFastMode(sessionID: String, isEnabled: Bool)
}

struct AnyCodingKey: CodingKey {
    let intValue: Int?
    let stringValue: String

    init?(intValue: Int) {
        self.intValue = intValue
        self.stringValue = String(intValue)
    }

    init?(stringValue: String) {
        self.intValue = nil
        self.stringValue = stringValue
    }
}
