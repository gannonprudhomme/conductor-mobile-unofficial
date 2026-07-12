//
//  MessageTests.swift
//  SharedConductorDataTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import Foundation
import SQLiteData
import Testing

struct MessageTests {
    @Test("Message decoding preserves unknown roles and nullable fields")
    func decoding() throws {
        let message = try JSONDecoder.conductor.decode(
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
        #expect(message.createdAt == Date(timeIntervalSince1970: 1_783_555_200))
        #expect(message.sentAt == Date(timeIntervalSince1970: 1_783_555_201))
        #expect(message.turnID == "turn-1")
        #expect(message.queueOrder == 1)
        #expect(message.senderID == nil)
    }

    @Test("Message SQLite decoding parses ISO-8601 and nullable dates")
    func sqliteDateDecoding() throws {
        let database = try DatabaseQueue()
        try database.write { db in
            try db.execute(
                sql: """
                    CREATE TABLE session_messages (
                      id TEXT PRIMARY KEY,
                      session_id TEXT,
                      role TEXT,
                      content TEXT,
                      created_at TEXT NOT NULL,
                      sent_at TEXT,
                      full_message TEXT,
                      cancelled_at TEXT,
                      model TEXT,
                      sdk_message_id TEXT,
                      last_assistant_message_id TEXT,
                      turn_id TEXT,
                      is_resumable_message INTEGER,
                      queue_order INTEGER,
                      sender_id TEXT
                    );
                    INSERT INTO session_messages (id, created_at, sent_at)
                    VALUES
                      ('message-null', '2026-07-09T00:00:01Z', NULL),
                      ('message-sent', '2026-07-09T00:00:02Z', '2026-07-09T00:00:03.125Z');
                    """
            )
        }

        let messages = try database.read { db in
            try Message
                .order(by: \.id)
                .fetchAll(db)
        }

        try #require(messages.count == 2)
        #expect(messages[0].createdAt == Date(timeIntervalSince1970: 1_783_555_201))
        #expect(messages[0].sentAt == nil)
        #expect(messages[1].createdAt == Date(timeIntervalSince1970: 1_783_555_202))
        #expect(messages[1].sentAt == Date(timeIntervalSince1970: 1_783_555_203.125))
    }
}
