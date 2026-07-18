//
//  Session+Preview.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
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
        model: Model = .gpt_5_6_sol,
        unreadCount: Int = 0,
        freshlyCompacted: Int = 0,
        contextTokenCount: Int = 0,
        isFastModeEnabled: Bool? = false
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
            contextTokenCount: contextTokenCount,
            isFastModeEnabled: isFastModeEnabled
        )
    }
}
