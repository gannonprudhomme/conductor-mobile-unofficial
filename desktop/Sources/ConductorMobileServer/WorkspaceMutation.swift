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

enum UIHookCommand: Equatable, Sendable {
    case workspace(id: String, mutation: WorkspaceMutation)
    case sessionFastMode(sessionID: String, isEnabled: Bool)
}
