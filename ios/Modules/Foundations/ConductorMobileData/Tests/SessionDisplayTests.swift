//
//  SessionDisplayTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
@testable import ConductorMobileData
import CustomDump
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
        #expect(session.updatedDate == Date(timeIntervalSince1970: 1_783_558_800))
    }

    @Test("Sessions use a fallback display title for null and empty titles")
    func fallbackDisplayTitle() {
        #expect(Session.preview(title: nil).displayTitle == "Untitled Session")
        #expect(Session.preview(title: "").displayTitle == "Untitled Session")
    }

    @Test("Agent types use known display names and preserve unknown values")
    func agentTypeDisplayName() {
        #expect(Session.AgentType.codex.displayName == "Codex")
        #expect(Session.AgentType(rawValue: "future-agent").displayName == "future-agent")
    }

    @Test("Models use known display names and preserve unknown values")
    func modelDisplayName() {
        let expectedDisplayNames = [
            (rawValue: "fable-5", displayName: "Fable 5"),
            (rawValue: "opus", displayName: "Opus"),
            (rawValue: "opus-1m", displayName: "Opus 1M"),
            (rawValue: "opus-5-1m", displayName: "Opus 5"),
            (rawValue: "opus-4-8-1m", displayName: "Opus 4.8 1M"),
            (rawValue: "opus-4-7-1m", displayName: "Opus 4.7 1M"),
            (rawValue: "opus-4-6-1m", displayName: "Opus 4.6 1M"),
            (rawValue: "sonnet-5-1m", displayName: "Sonnet 5 1M"),
            (rawValue: "sonnet-4-6-1m", displayName: "Sonnet 4.6 1M"),
            (rawValue: "sonnet", displayName: "Sonnet 4.6"),
            (rawValue: "haiku", displayName: "Haiku 4.5"),
            (rawValue: "gpt-5.6-sol", displayName: "GPT-5.6 Sol"),
            (rawValue: "gpt-5.6-terra", displayName: "GPT-5.6 Terra"),
            (rawValue: "gpt-5.6-luna", displayName: "GPT-5.6 Luna"),
            (rawValue: "gpt-5.5", displayName: "GPT-5.5"),
            (rawValue: "gpt-5.4", displayName: "GPT-5.4"),
            (rawValue: "gpt-5.3-codex", displayName: "GPT-5.3 Codex"),
            (rawValue: "future-model", displayName: "future-model"),
        ]

        for (rawValue, displayName) in expectedDisplayNames {
            expectNoDifference(Session.Model(rawValue: rawValue).displayName, displayName)
        }
    }

    @Test("Models provide known fallback context window limits")
    func modelContextWindowLimits() {
        let oneMillionTokenModels: [Session.Model] = [
            .fable5,
            .opus_1M,
            .opus5_1M,
            .opus4_8_1M,
            .opus4_7_1M,
            .opus4_6_1M,
            .sonnet5_1M,
            .sonnet_4_6_1M,
        ]
        let standardClaudeModels: [Session.Model] = [
            .opus,
            .sonnet_4_6,
            .haiku4_5,
        ]
        let codexModels: [Session.Model] = [
            .gpt_5_6_sol,
            .gpt_5_6_terra,
            .gpt_5_6_luna,
            .gpt5_5,
            .gpt5_4,
            .gpt5_3Codex,
        ]

        for model in oneMillionTokenModels {
            #expect(model.fallbackContextWindowTokenLimit == 1_000_000)
        }
        for model in standardClaudeModels {
            #expect(model.fallbackContextWindowTokenLimit == 200_000)
        }
        for model in codexModels {
            #expect(model.fallbackContextWindowTokenLimit == 272_000)
        }
        #expect(
            Session.Model(rawValue: "future-model").fallbackContextWindowTokenLimit == nil
        )
    }

    @Test("Reasoning efforts use readable labels")
    func reasoningEffortDisplayName() {
        #expect(Session.ReasoningEffort.none.displayName == "Default")
        #expect(Session.ReasoningEffort.low.displayName == "Light")
        #expect(Session.ReasoningEffort.extraHigh.displayName == "Extra high")
        #expect(Session.ReasoningEffort.max.displayName == "Max")
        #expect(Session.ReasoningEffort.ultra.displayName == "Ultra")
        #expect(Session.ReasoningEffort.ultracode.displayName == "Ultra")
    }
}
