//
//  SessionDisplayTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
@testable import ConductorMobileData
import Foundation
import Testing

struct SessionDisplayTests {
    @Test("Sessions derive display values from Conductor fields")
    func displayValues() throws {
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
                  "unread_count": 0,
                  "freshly_compacted": 0,
                  "context_token_count": 1234
                }
                """.utf8
            )
        )

        #expect(session.displayTitle == "Investigate desktop bridge")
        #expect(session.debugSubtitle == "waiting_on_tool | gpt-5.3-codex | codex")
        #expect(session.displayModelName == "GPT-5.3 Codex")
        #expect(
            session.availableReasoningEfforts
                == [.low, .medium, .high, .extraHigh]
        )
        #expect(session.updatedDate == Date(timeIntervalSince1970: 1_783_558_800))
    }

    @Test("Agent types use known display names and preserve unknown values")
    func agentTypeDisplayName() {
        #expect(Session.AgentType.codex.displayName == "Codex")
        #expect(Session.AgentType(rawValue: "future-agent").displayName == "future-agent")
    }

    @Test("Reasoning effort labels follow the selected agent")
    func reasoningEffortDisplayName() {
        #expect(Session.ReasoningEffort.extraHigh.displayName(agentType: .codex) == "Extra high")
        #expect(Session.ReasoningEffort.extraHigh.displayName(agentType: .claude) == "Max")
        #expect(Session.ReasoningEffort.ultra.displayName(agentType: .codex) == "Ultra")
    }

    @Test("Reasoning effort cycles through the selected model's options")
    func nextReasoningEffort() {
        let session = Session.preview(model: "gpt-5.6-sol")

        #expect(session.nextReasoningEffort(after: .none) == .low)
        #expect(session.nextReasoningEffort(after: .high) == .extraHigh)
        #expect(session.nextReasoningEffort(after: .ultra) == .low)
    }
}
