//
//  ConciseTranscriptTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/19/26.
//

import Foundation
import SharedConductorData
import Testing

@testable import ConductorMobileData

struct ConciseTranscriptTests {
    @Test("Transcript preserves user text and the final assistant response")
    func finalResponse() {
        let transcript = ConciseTranscript.format([
            message(id: "user", role: .user, content: "Archive workspace UI"),
            message(
                id: "tool",
                role: .assistant,
                content: #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-1","name":"Read"}]}}"#
            ),
            message(
                id: "response",
                role: .assistant,
                content: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Implemented it."}]}}"#
            ),
        ])

        #expect(
            transcript == """
            ## User

            Archive workspace UI

            ## Assistant

            [1 message elided]

            Implemented it.
            """
        )
    }

    @Test("Transcript omits cancelled and orphaned messages")
    func omittedMessages() {
        #expect(
            ConciseTranscript.format([
                message(id: "orphan", role: .assistant, content: "{}", turnID: nil),
                message(
                    id: "cancelled",
                    role: .user,
                    content: "Never sent",
                    cancelledAt: "2026-07-19"
                ),
            ]) == nil
        )
    }

    @Test("Transcript sanitizes attachments and collapses compaction events")
    func compaction() {
        let transcript = ConciseTranscript.format([
            message(
                id: "user",
                role: .user,
                content: "@⟦image.png⟧(.context%2Fattachments%2Fimage.png) Review this."
            ),
            message(
                id: "compacting",
                role: .assistant,
                content: #"{"type":"system","subtype":"status","status":"compacting"}"#
            ),
            message(
                id: "boundary",
                role: .assistant,
                content: #"{"type":"system","subtype":"compact_boundary"}"#
            ),
            message(
                id: "response",
                role: .assistant,
                content: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}"#
            ),
        ])

        #expect(
            transcript == """
            ## User

            @image.png Review this.

            ## Assistant

            [1 message elided]

            Done.
            """
        )
    }

    @Test("Transcript preserves unknown external event and block states")
    func unknownExternalStates() {
        let transcript = ConciseTranscript.format([
            message(id: "user", role: .user, content: "Continue"),
            message(
                id: "unknown-event",
                role: .assistant,
                content: #"{"type":"future_event","subtype":"future_subtype","status":"future_status"}"#
            ),
            message(
                id: "unknown-block",
                role: .assistant,
                content: #"{"type":"assistant","message":{"content":[{"type":"future_block","text":"Ignore"}]}}"#
            ),
            message(
                id: "response",
                role: .assistant,
                content: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}"#
            ),
        ])

        #expect(
            transcript == """
            ## User

            Continue

            ## Assistant

            [2 messages elided]

            Done.
            """
        )
    }

    @Test("Transcript preserves speaker order within a turn")
    func speakerOrder() {
        let transcript = ConciseTranscript.format([
            message(id: "user-a", role: .user, content: "User A"),
            message(
                id: "assistant-a",
                role: .assistant,
                content: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Assistant A"},{"type":"tool_use","id":"question","name":"AskUserQuestion"}]}}"#
            ),
            message(id: "user-b", role: .user, content: "User B"),
            message(
                id: "assistant-b",
                role: .assistant,
                content: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Assistant B"}]}}"#
            ),
        ])

        #expect(
            transcript == """
            ## User

            User A

            ## Assistant

            Assistant A

            [1 tool call elided]

            ## User

            User B

            ## Assistant

            Assistant B
            """
        )
    }

    private func message(
        id: String,
        role: Message.Role,
        content: String,
        turnID: String? = "turn-1",
        cancelledAt: String? = nil
    ) -> Message {
        Message(
            id: id,
            role: role,
            content: content,
            createdAt: .distantPast,
            cancelledAt: cancelledAt,
            turnID: turnID
        )
    }
}
