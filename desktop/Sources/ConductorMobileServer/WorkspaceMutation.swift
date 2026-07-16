//
//  WorkspaceMutation.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/15/26.
//

enum WorkspaceMutation: Equatable, Sendable {
    case pinned(isPinned: Bool)
    case status(String)
    case unread(isUnread: Bool)
}
