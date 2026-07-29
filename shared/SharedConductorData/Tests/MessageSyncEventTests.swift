//
//  MessageSyncEventTests.swift
//  SharedConductorDataTests
//
//  Created by Gannon Prudomme on 7/29/26.
//

import Foundation
@testable import SharedConductorData
import Testing

struct MessageSyncEventTests {
    @Test("The event envelope uses cursor and optional complete queue snapshot fields")
    func coding() throws {
        let queued = Message(
            id: "queued",
            sessionID: "session",
            role: .user,
            content: "Later",
            createdAt: Date(timeIntervalSince1970: 2),
            queueOrder: 0
        )
        let event = MessageSyncEvent.changes(
            cursor: "completed",
            queuedMessages: [queued]
        )

        let data = try JSONEncoder.conductor.encode(event)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["cursor"] as? String == "completed")
        #expect((object["queued_messages"] as? [[String: Any]])?.count == 1)
        #expect(object["checkpoint"] == nil)
        #expect(
            try JSONDecoder.conductor.decode(MessageSyncEvent.self, from: data)
                == event
        )
    }

    @Test("An absent queue snapshot means the queue is unchanged")
    func absentQueueSnapshot() throws {
        let event = MessageSyncEvent.changes(cursor: "completed")
        let data = try JSONEncoder.conductor.encode(event)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["queued_messages"] == nil)
        #expect(
            try JSONDecoder.conductor.decode(MessageSyncEvent.self, from: data)
                .queuedMessages == nil
        )
    }

    @Test("Legacy full snapshots decode with absent new optional fields")
    func legacySnapshot() throws {
        let data = Data(
            """
            {
              "is_snapshot": true,
              "messages": [
                {
                  "id": "completed",
                  "session_id": "session",
                  "created_at": "2026-07-29T00:00:00Z",
                  "sent_at": "2026-07-29T00:00:01Z"
                },
                {
                  "id": "queued",
                  "session_id": "session",
                  "created_at": "2026-07-29T00:00:02Z",
                  "queue_order": 0
                }
              ],
              "deleted_message_ids": []
            }
            """.utf8
        )

        let event = try JSONDecoder.conductor.decode(MessageSyncEvent.self, from: data)

        #expect(event.isSnapshot)
        #expect(event.messages.map(\.id) == ["completed", "queued"])
        #expect(event.queuedMessages == nil)
        #expect(event.cursor == nil)
    }
}
