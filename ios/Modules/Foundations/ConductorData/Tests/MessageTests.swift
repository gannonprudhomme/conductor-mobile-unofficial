import ConductorData
import Foundation
import Testing

struct MessageTests {
    @Test("Message decoding preserves unknown roles and nullable fields")
    func decoding() throws {
        let message = try JSONDecoder().decode(
            Message.self,
            from: Data(
                """
                {
                  "id": "message-1",
                  "session_id": "session-1",
                  "role": "assistant",
                  "content": "On it.",
                  "created_at": "2026-07-09 00:00:00",
                  "sent_at": "2026-07-09 00:00:01",
                  "full_message": null,
                  "cancelled_at": null,
                  "model": "opus-4-8-1m",
                  "sdk_message_id": null,
                  "last_assistant_message_id": null,
                  "turn_id": "turn-1",
                  "is_resumable_message": null,
                  "queue_order": 1,
                  "sender_id": null
                }
                """.utf8
            )
        )

        #expect(message.id == "message-1")
        #expect(message.role == .assistant)
        #expect(message.content == "On it.")
        #expect(message.turnID == "turn-1")
        #expect(message.queueOrder == 1)
        #expect(message.senderID == nil)
    }
}
