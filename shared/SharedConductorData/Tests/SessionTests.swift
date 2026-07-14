//
//  SessionTests.swift
//  SharedConductorDataTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import Foundation
import Testing

struct SessionTests {
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
                  "permission_mode": "future-permission-mode",
                  "codex_thinking_level": "future-effort",
                  "fast_mode": true,
                  "agent_personality": "future-personality",
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
        #expect(session.permissionMode?.rawValue == "future-permission-mode")
        #expect(session.reasoningEffort?.rawValue == "future-effort")
        #expect(session.fastMode == true)
        #expect(session.agentPersonality?.rawValue == "future-personality")
    }

    @Test("Agent options use Conductor's JSON keys")
    func agentOptionsCoding() throws {
        let options = Session.AgentOptions(
            fastMode: true,
            reasoningEffort: .ultra
        )
        let data = try JSONEncoder().encode(options)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["fast_mode"] as? Bool == true)
        #expect(object["reasoning_effort"] as? String == "ultra")
    }
}
