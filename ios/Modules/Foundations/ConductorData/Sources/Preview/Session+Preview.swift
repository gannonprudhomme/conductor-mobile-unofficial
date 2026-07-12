//
//  Session+Preview.swift
//  ConductorData
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Foundation

extension Session {
    public static func preview(
        id: String = "session-1",
        workspaceID: String = "workspace-1",
        title: String = "Session",
        agentType: AgentType = .codex,
        isHidden: Bool = false,
        createdAt: String = "2026-06-25T09:30:00.000Z",
        updatedAt: String = "2026-06-25T09:30:00.000Z",
        lastUserMessageAt: String? = nil,
        status: Status = .idle,
        model: String = "gpt-5",
        unreadCount: Int = 0,
        freshlyCompacted: Int = 0,
        contextTokenCount: Int = 0
    ) -> Self {
        Self(
            id: id,
            workspaceID: workspaceID,
            title: title,
            agentType: agentType,
            isHidden: isHidden,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastUserMessageAt: lastUserMessageAt,
            status: status,
            model: model,
            unreadCount: unreadCount,
            freshlyCompacted: freshlyCompacted,
            contextTokenCount: contextTokenCount
        )
    }
}
