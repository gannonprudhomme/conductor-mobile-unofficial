import ComposableArchitecture
import ConductorData
import CustomDump
import Foundation
import SQLiteData
@testable import ConductorChat
import Testing

@MainActor
struct ChatTests {
    #if DEBUG
    @Test("Pagination performance preview contains the complete session")
    func previewContent() throws {
        let content = try DiscussPaginationPerformancePreviewContent()

        #expect(content.session.id == "34541fbc-44b2-415a-9adb-574093ece33f")
        #expect(content.session.title == "Discuss Pagination Performance")
        #expect(content.messages.count == 142)
        #expect(Set(content.messages.map(\.id)).count == 142)
        #expect(content.messages.allSatisfy { $0.sessionID == content.session.id })
        #expect(content.messages.filter { $0.role == .user }.count == 5)
        #expect(content.messages.filter { $0.role == .assistant }.count == 137)

        for message in content.messages where message.role == .assistant {
            let event = try #require(message.content)
            _ = try JSONSerialization.jsonObject(with: Data(event.utf8))
        }
    }
    #endif

    @Test("Messages are limited to the selected session and ordered chronologically")
    func messagesAreScopedAndOrdered() throws {
        let earlyMessage = try makeMessage(
            id: "early",
            sessionID: "session-1",
            createdAt: "2026-07-09 01:00:00"
        )
        let lateMessage = try makeMessage(
            id: "late",
            sessionID: "session-1",
            createdAt: "2026-07-09 02:00:00"
        )
        let otherMessage = try makeMessage(
            id: "other",
            sessionID: "session-2",
            createdAt: "2026-07-09 00:00:00"
        )

        try withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Message.upsert { lateMessage }.execute(db)
                try Message.upsert { otherMessage }.execute(db)
                try Message.upsert { earlyMessage }.execute(db)
            }
        } operation: {
            let state = Chat.State(session: try makeSession())

            expectNoDifference(
                state.messages,
                [earlyMessage, lateMessage]
            )
        }
    }

    @Test("Selecting and dismissing a message controls the sheet")
    func messageSelectionControlsSheet() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let message = try makeMessage(
                id: "message-1",
                sessionID: "session-1",
                createdAt: "2026-07-09 01:00:00"
            )
            let session = try makeSession()
            let store = TestStore(initialState: Chat.State(session: session)) {
                Chat()
            }

            await store.send(.messageTapped(message)) {
                $0.destination = .message(message)
            }
            await store.send(.destination(.dismiss)) {
                $0.destination = nil
            }
        }
    }
}

private func makeMessage(
    id: String,
    sessionID: String,
    createdAt: String
) throws -> Message {
    try JSONDecoder().decode(
        Message.self,
        from: Data(
            """
            {
              "id": "\(id)",
              "session_id": "\(sessionID)",
              "role": "assistant",
              "content": "Message \(id)",
              "created_at": "\(createdAt)"
            }
            """.utf8
        )
    )
}

private func makeSession() throws -> Session {
    try JSONDecoder().decode(
        Session.self,
        from: Data(
            """
            {
              "id": "session-1",
              "workspace_id": "workspace-1",
              "title": "Chat",
              "agent_type": "codex",
              "is_hidden": false,
              "created_at": "2026-07-09 00:00:00",
              "updated_at": "2026-07-09 00:00:00",
              "status": "idle",
              "model": "gpt-5",
              "unread_count": 0,
              "freshly_compacted": 0,
              "context_token_count": 0
            }
            """.utf8
        )
    )
}
