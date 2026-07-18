//
//  ModelPickerTests.swift
//  ConductorDesignTests
//
//  Created by Gannon Prudomme on 7/13/26.
//

import SharedConductorData
@testable import ConductorDesign
import Testing

@MainActor
struct ModelPickerTests {
    @Test("Menu equality only tracks values that change its contents")
    func equality() {
        let picker = ModelPicker(
            agentType: .codex,
            allowsAgentSwitching: true,
            selectedModel: .gpt_5_6_sol,
            onSelect: { _ in }
        )

        #expect(
            picker == ModelPicker(
                agentType: .codex,
                allowsAgentSwitching: true,
                selectedModel: .gpt_5_6_sol,
                onSelect: { _ in }
            )
        )
        #expect(
            picker != ModelPicker(
                agentType: .codex,
                allowsAgentSwitching: true,
                selectedModel: .gpt_5_6_terra,
                onSelect: { _ in }
            )
        )
        #expect(picker.allowsSelection(for: .claude))
        #expect(picker.allowsSelection(for: .codex))

        let lockedPicker = ModelPicker(
            agentType: .codex,
            selectedModel: .gpt_5_6_sol,
            onSelect: { _ in }
        )
        #expect(!lockedPicker.allowsSelection(for: .claude))
        #expect(lockedPicker.allowsSelection(for: .codex))
        #expect(
            picker != ModelPicker(
                agentType: .claude,
                allowsAgentSwitching: true,
                selectedModel: .gpt_5_6_sol,
                onSelect: { _ in }
            )
        )
        #expect(
            picker != ModelPicker(
                agentType: .codex,
                allowsAgentSwitching: false,
                selectedModel: .gpt_5_6_sol,
                onSelect: { _ in }
            )
        )
    }
}
