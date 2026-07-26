//
//  QueriesTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/15/26.
//

import SharedConductorData
import SQLiteData
import Testing

@testable import ConductorMobileServer

struct QueriesTests {
    @Test("Message query excludes tool results and includes queued messages")
    func messagesExcludeToolResults() throws {
        let database = try testConductorDatabase()
        try database.write { database in
            try database.execute(
                sql: """
                    INSERT INTO workspaces (id, created_at, updated_at)
                    VALUES ('workspace', '2026-07-15T00:00:00Z', '2026-07-15T00:00:00Z');

                    INSERT INTO sessions (
                      id, workspace_id, title, agent_type, created_at, updated_at, status, model
                    ) VALUES (
                      'session', 'workspace', 'Session', 'codex',
                      '2026-07-15T00:00:00Z', '2026-07-15T00:00:00Z', 'idle', 'gpt-5'
                    );

                    INSERT INTO session_messages (
                      id, session_id, role, content, created_at
                    ) VALUES
                      (
                        'human', 'session', 'user', 'Run the tests',
                        '2026-07-15T00:00:01Z'
                      ),
                      (
                        'tool-use', 'session', 'assistant',
                        '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool","name":"Bash","input":{"command":"swift test"}}]}}',
                        '2026-07-15T00:00:02Z'
                      ),
                      (
                        'tool-result', 'session', 'assistant',
                        '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool","content":"Passed","is_error":false}]}}',
                        '2026-07-15T00:00:03Z'
                      ),
                      (
                        'text', 'session', 'assistant',
                        '{"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}',
                        '2026-07-15T00:00:04Z'
                      ),
                      (
                        'queued', 'session', 'user', 'Run the integration tests',
                        '2026-07-15T00:00:05Z'
                      );
                    UPDATE session_messages SET queue_order = 1 WHERE id = 'queued';
                    """
            )
        }

        let messages = try database.read { database in
            try Message
                .all(forWorkspaceID: "workspace", sessionID: "session")
                .fetchAll(database)
        }

        #expect(messages.map(\.id) == ["human", "tool-use", "text", "queued"])
        #expect(messages.last?.sentAt == nil)
        #expect(messages.last?.queueOrder == 1)
    }
}
