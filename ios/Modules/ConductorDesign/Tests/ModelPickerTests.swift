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
    @Test("Reasoning effort fills zero through six bars")
    func reasoningEffortActiveBarCounts() {
        #expect(Session.ReasoningEffort.none.activeBarCount == 0)
        #expect(Session.ReasoningEffort.low.activeBarCount == 1)
        #expect(Session.ReasoningEffort.medium.activeBarCount == 2)
        #expect(Session.ReasoningEffort.high.activeBarCount == 3)
        #expect(Session.ReasoningEffort.extraHigh.activeBarCount == 4)
        #expect(Session.ReasoningEffort.max.activeBarCount == 5)
        #expect(Session.ReasoningEffort.ultra.activeBarCount == 6)
        #expect(Session.ReasoningEffort.ultracode.activeBarCount == 6)
    }

    @Test("Only Ultra efforts use the special appearance")
    func ultraAppearance() {
        #expect(!Session.ReasoningEffort.max.usesUltraAppearance)
        #expect(Session.ReasoningEffort.ultra.usesUltraAppearance)
        #expect(Session.ReasoningEffort.ultracode.usesUltraAppearance)
    }

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
        #expect(
            picker != ModelPicker(
                agentType: .codex,
                allowsAgentSwitching: true,
                selectedModel: .gpt_5_6_sol,
                showsName: false,
                onSelect: { _ in }
            )
        )
    }
}
