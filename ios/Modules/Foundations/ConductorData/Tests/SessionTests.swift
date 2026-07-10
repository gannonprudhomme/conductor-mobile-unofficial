import ConductorData
import Foundation
import Testing

struct SessionTests {
    @Test("Session decoding preserves unknown statuses and provides display values")
    func decodingAndDisplayValues() throws {
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

        #expect(session.status.rawValue == "waiting_on_tool")
        #expect(session.agentType == .codex)
        #expect(session.agentType.displayName == "Codex")
        #expect(Session.AgentType(rawValue: "future-agent").displayName == "future-agent")
        #expect(session.isHidden)
        #expect(session.displayTitle == "Investigate desktop bridge")
        #expect(session.debugSubtitle == "waiting_on_tool | gpt-5.3-codex | codex")
        #expect(session.updatedDate == Date(timeIntervalSince1970: 1_783_558_800))
    }
}
