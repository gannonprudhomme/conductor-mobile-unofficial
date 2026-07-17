//
//  ChatModelPickerTests.swift
//  ConductorChatTests
//
//  Created by Gannon Prudomme on 7/13/26.
//

import SharedConductorData
import Testing

@testable import ConductorChat

@MainActor
struct ChatModelPickerTests {
    @Test("Menu equality only tracks values that change its contents")
    func equality() {
        let picker = ChatModelPicker(
            agentType: .codex,
            selectedModel: .gpt_5_6_sol,
            onSelect: { _ in }
        )

        #expect(
            picker == ChatModelPicker(
                agentType: .codex,
                selectedModel: .gpt_5_6_sol,
                onSelect: { _ in }
            )
        )
        #expect(
            picker != ChatModelPicker(
                agentType: .codex,
                selectedModel: .gpt_5_6_terra,
                onSelect: { _ in }
            )
        )
        #expect(
            picker != ChatModelPicker(
                agentType: .claude,
                selectedModel: .gpt_5_6_sol,
                onSelect: { _ in }
            )
        )
    }
}
