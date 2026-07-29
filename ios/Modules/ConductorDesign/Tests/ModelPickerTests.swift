//
//  ModelPickerTests.swift
//  ConductorDesignTests
//
//  Created by Gannon Prudomme on 7/13/26.
//

import SharedConductorData
import SwiftUI
@testable import ConductorDesign
import Testing
import UIKit

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

    @Test("Read-only controls expose stable values and stay enabled")
    func readOnlyPresentation() {
        let taps = TapRecorder()
        let controls = ModelAndFastModeControls(
            agentType: .claude,
            availableReasoningEfforts: [],
            interactionMode: .readOnlyInformational,
            isFastModeEnabled: false,
            isFastModeButtonDisabled: true,
            selectedModel: Session.Model(rawValue: ""),
            selectedReasoningEffort: nil,
            onFastModeTapped: {
                taps.editableTapCount += 1
            },
            onInformationalControlTapped: {
                taps.informationalControls.append($0)
            },
            onSelectReasoningEffort: { _ in
                taps.editableTapCount += 1
            },
            onSelectModel: { _ in
                taps.editableTapCount += 1
            }
        )

        #expect(controls.displayedModelAgentType == .claude)
        #expect(controls.displayedModelName == "Default")
        #expect(controls.displayedReasoningEffortName == "Default")
        #expect(controls.displayedFastModeName == "Off")
        #expect(controls.isReasoningEffortControlVisible)
        #expect(!controls.isDisabledDuringAction(.model))
        #expect(!controls.isDisabledDuringAction(.reasoningEffort))
        #expect(!controls.isDisabledDuringAction(.fastMode))
        #expect(
            controls.readOnlyAccessibilityHint
                == "Double-tap to learn why this setting can’t be changed."
        )
        #expect(
            ModelConfigurationControl.model.accessibilityIdentifier
                == "configuration.model"
        )
        #expect(
            ModelConfigurationControl.reasoningEffort
                .accessibilityIdentifier
                == "configuration.reasoningEffort"
        )
        #expect(
            ModelConfigurationControl.fastMode.accessibilityIdentifier
                == "configuration.fastMode"
        )

        controls.onInformationalControlTapped(.model)
        controls.onInformationalControlTapped(.reasoningEffort)
        controls.onInformationalControlTapped(.fastMode)
        #expect(
            taps.informationalControls
                == [.model, .reasoningEffort, .fastMode]
        )
        #expect(taps.editableTapCount == 0)
    }

    @Test("Read-only controls preserve unknown reported values")
    func unknownReadOnlyValues() {
        let knownControls = ModelAndFastModeControls(
            agentType: .codex,
            availableReasoningEfforts: [.low, .high],
            interactionMode: .readOnlyInformational,
            isFastModeEnabled: true,
            selectedModel: .gpt5_5,
            selectedReasoningEffort: .high,
            onFastModeTapped: { },
            onSelectReasoningEffort: { _ in },
            onSelectModel: { _ in }
        )
        let controls = ModelAndFastModeControls(
            agentType: .codex,
            availableReasoningEfforts: [],
            interactionMode: .readOnlyInformational,
            isFastModeEnabled: true,
            selectedModel: Session.Model(rawValue: "future-model"),
            selectedReasoningEffort: Session.ReasoningEffort(
                rawValue: "future-effort"
            ),
            onFastModeTapped: { },
            onSelectReasoningEffort: { _ in },
            onSelectModel: { _ in }
        )

        #expect(knownControls.displayedModelName == "GPT-5.5")
        #expect(knownControls.displayedReasoningEffortName == "High")
        #expect(knownControls.displayedFastModeName == "On")
        #expect(controls.displayedModelName == "future-model")
        #expect(
            controls.displayedReasoningEffortName == "Future-Effort"
        )
        #expect(controls.displayedFastModeName == "On")
        #expect(controls.isReasoningEffortControlVisible)
    }

    @Test("Editable and read-only controls keep matching layout heights")
    func interactionModeLayoutParity() {
        let editable = ModelAndFastModeControls(
            agentType: .codex,
            availableReasoningEfforts: [.low, .medium, .high],
            interactionMode: .editable,
            isFastModeEnabled: true,
            selectedModel: .gpt5_5,
            selectedReasoningEffort: .high,
            onFastModeTapped: { },
            onSelectReasoningEffort: { _ in },
            onSelectModel: { _ in }
        )
        let readOnlyKnown = ModelAndFastModeControls(
            agentType: .codex,
            availableReasoningEfforts: [.low, .medium, .high],
            interactionMode: .readOnlyInformational,
            isFastModeEnabled: true,
            selectedModel: .gpt5_5,
            selectedReasoningEffort: .high,
            onFastModeTapped: { },
            onSelectReasoningEffort: { _ in },
            onSelectModel: { _ in }
        )
        let readOnlyDefault = ModelAndFastModeControls(
            agentType: .codex,
            availableReasoningEfforts: [],
            interactionMode: .readOnlyInformational,
            isFastModeEnabled: false,
            selectedModel: Session.Model(rawValue: ""),
            selectedReasoningEffort: nil,
            onFastModeTapped: { },
            onSelectReasoningEffort: { _ in },
            onSelectModel: { _ in }
        )
        let readOnlyUnknown = ModelAndFastModeControls(
            agentType: .codex,
            availableReasoningEfforts: [],
            interactionMode: .readOnlyInformational,
            isFastModeEnabled: true,
            selectedModel: Session.Model(rawValue: "future-model"),
            selectedReasoningEffort: Session.ReasoningEffort(
                rawValue: "future-effort"
            ),
            onFastModeTapped: { },
            onSelectReasoningEffort: { _ in },
            onSelectModel: { _ in }
        )

        for dynamicTypeSize in [
            DynamicTypeSize.large,
            .xxLarge,
        ] {
            let editableHeight = fittingHeight(
                of: editable,
                dynamicTypeSize: dynamicTypeSize
            )
            for readOnly in [
                AnyView(readOnlyKnown),
                AnyView(readOnlyDefault),
                AnyView(readOnlyUnknown),
            ] {
                let readOnlyHeight = fittingHeight(
                    of: readOnly,
                    dynamicTypeSize: dynamicTypeSize
                )
                #expect(
                    abs(readOnlyHeight - editableHeight) < 0.5
                )
            }
        }
    }
}

@MainActor
private func fittingHeight<Content: View>(
    of content: Content,
    dynamicTypeSize: DynamicTypeSize
) -> CGFloat {
    let hostingController = UIHostingController(
        rootView: AnyView(
            content
                .environment(\.dynamicTypeSize, dynamicTypeSize)
                .frame(width: 390, alignment: .leading)
                .background(.theme(.background))
                .preferredColorScheme(.dark)
        )
    )
    return hostingController.sizeThatFits(
        in: CGSize(
            width: 390,
            height: CGFloat.greatestFiniteMagnitude
        )
    ).height
}

@MainActor
private final class TapRecorder {
    var editableTapCount = 0
    var informationalControls: [ModelConfigurationControl] = []
}
