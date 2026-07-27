//
//  SessionTests.swift
//  SharedConductorDataTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Foundation
import SharedConductorData
import Testing

struct SessionTests {
    @Test("Session models match the desktop catalog")
    func modelCatalog() {
        #expect(
            Session.Model.claudeModels.map(\.rawValue) == [
                "fable-5",
                "opus-4-8-1m",
                "opus-4-7-1m",
                "opus-4-6-1m",
                "sonnet-5-1m",
                "sonnet-4-6-1m",
                "sonnet",
                "haiku",
            ]
        )
        #expect(
            Session.Model.codexModels.map(\.rawValue) == [
                "gpt-5.6-sol",
                "gpt-5.6-terra",
                "gpt-5.6-luna",
                "gpt-5.5",
                "gpt-5.4",
            ]
        )
        #expect(Session.Model.fable5.agentType == .claude)
        #expect(Session.Model.gpt_5_6_sol.agentType == .codex)
        #expect(Session.Model(rawValue: "future-model").agentType == nil)
    }

    @Test("Session decoding preserves unknown schema values")
    func decoding() throws {
        let session = try JSONDecoder().decode(
            Session.self,
            from: Data(
                """
                {
                  "id": "session-1",
                  "workspace_id": "workspace-1",
                  "title": "Investigate desktop bridge",
                  "agent_type": "codex",
                  "is_hidden": true,
                  "created_at": "2026-07-09 00:00:00",
                  "updated_at": "2026-07-09 01:00:00",
                  "last_user_message_at": null,
                  "status": "waiting_on_tool",
                  "model": "gpt-5.3-codex",
                  "codex_thinking_level": "future-effort",
                  "fast_mode": true,
                  "claude_effort_level": null,
                  "unread_count": 0,
                  "freshly_compacted": 0,
                  "context_token_count": 1234
                }
                """.utf8
            )
        )

        #expect(session.status.rawValue == "waiting_on_tool")
        #expect(session.agentType == .codex)
        #expect(session.isHidden)
        #expect(session.isFastModeEnabled == true)
        #expect(session.reasoningEffort?.rawValue == "future-effort")
    }

    @Test("Reasoning efforts match each model configuration")
    func reasoningEfforts() {
        #expect(
            Session.Model.gpt_5_6_sol.availableCodexReasoningEfforts
                == [.none, .low, .medium, .high, .extraHigh, .max, .ultra]
        )
        #expect(
            Session.Model.gpt_5_6_terra.availableCodexReasoningEfforts
                == [.none, .low, .medium, .high, .extraHigh, .max, .ultra]
        )
        #expect(
            Session.Model.gpt_5_6_luna.availableCodexReasoningEfforts
                == [.none, .low, .medium, .high, .extraHigh, .max]
        )
        #expect(
            Session.Model.gpt5_5.availableCodexReasoningEfforts
                == [.none, .low, .medium, .high, .extraHigh]
        )

        let claudeSession = Session(
            id: "session-1",
            workspaceID: "workspace-1",
            title: "Claude",
            agentType: .claude,
            isHidden: false,
            createdAt: "2026-07-09 00:00:00",
            updatedAt: "2026-07-09 00:00:00",
            lastUserMessageAt: nil,
            status: .idle,
            model: .fable5,
            unreadCount: 0,
            freshlyCompacted: 0,
            contextTokenCount: 0,
            claudeEffortLevel: .high
        )
        #expect(
            claudeSession.availableReasoningEfforts(for: .fable5)
                == [.low, .medium, .high, .extraHigh, .max, .ultracode]
        )
        #expect(!claudeSession.availableReasoningEfforts(for: .fable5).contains(.ultra))

        var crossAgentSession = claudeSession
        crossAgentSession.agentType = .codex
        crossAgentSession.model = .gpt5_5
        crossAgentSession.claudeEffortLevel = nil
        #expect(
            crossAgentSession.availableReasoningEfforts(for: .fable5)
                == [.low, .medium, .high, .extraHigh, .max, .ultracode]
        )

        #expect(
            claudeSession.availableReasoningEfforts(for: .opus4_6_1M)
                == [.low, .medium, .high, .max]
        )
        #expect(claudeSession.availableReasoningEfforts(for: .haiku4_5).isEmpty)
    }
}
