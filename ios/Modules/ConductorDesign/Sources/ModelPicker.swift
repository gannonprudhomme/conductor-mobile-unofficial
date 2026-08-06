//
//  ModelPicker.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/13/26.
//

import ConductorMobileData
import LucideIcons
import SharedConductorData
import SwiftUI

public enum ModelConfigurationControl: Equatable, Sendable {
    case model
    case reasoningEffort
    case fastMode

    var accessibilityIdentifier: String {
        switch self {
        case .model:
            "configuration.model"
        case .reasoningEffort:
            "configuration.reasoningEffort"
        case .fastMode:
            "configuration.fastMode"
        }
    }
}

public enum ModelConfigurationInteractionMode: Equatable, Sendable {
    case editable
    case readOnlyInformational
    case hidden
}

public struct ModelAndFastModeControls: View {
    let agentType: Session.AgentType
    let allowsAgentSwitching: Bool
    let allowedModels: Set<Session.Model>?
    let availableReasoningEfforts: [Session.ReasoningEffort]
    let interactionMode: ModelConfigurationInteractionMode
    let isFastModeEnabled: Bool
    let isFastModeButtonDisabled: Bool
    let showsFastMode: Bool
    let selectedModel: Session.Model
    let selectedModelTitle: String?
    let selectedReasoningEffort: Session.ReasoningEffort?
    let onFastModeTapped: @MainActor () -> Void
    let onInformationalControlTapped: @MainActor (ModelConfigurationControl) -> Void
    let onSelectReasoningEffort: @MainActor (Session.ReasoningEffort) -> Void
    let onSelectModel: @MainActor (Session.Model) -> Void

    public init(
        agentType: Session.AgentType,
        allowsAgentSwitching: Bool = false,
        allowedModels: Set<Session.Model>? = nil,
        availableReasoningEfforts: [Session.ReasoningEffort],
        interactionMode: ModelConfigurationInteractionMode = .editable,
        isFastModeEnabled: Bool,
        isFastModeButtonDisabled: Bool = false,
        showsFastMode: Bool = true,
        selectedModel: Session.Model,
        selectedModelTitle: String? = nil,
        selectedReasoningEffort: Session.ReasoningEffort?,
        onFastModeTapped: @escaping @MainActor () -> Void,
        onInformationalControlTapped: @escaping @MainActor (
            ModelConfigurationControl
        ) -> Void = { _ in },
        onSelectReasoningEffort: @escaping @MainActor (Session.ReasoningEffort) -> Void,
        onSelectModel: @escaping @MainActor (Session.Model) -> Void
    ) {
        self.agentType = agentType
        self.allowsAgentSwitching = allowsAgentSwitching
        self.allowedModels = allowedModels
        self.availableReasoningEfforts = availableReasoningEfforts
        self.interactionMode = interactionMode
        self.isFastModeEnabled = isFastModeEnabled
        self.isFastModeButtonDisabled = isFastModeButtonDisabled
        self.showsFastMode = showsFastMode
        self.selectedModel = selectedModel
        self.selectedModelTitle = selectedModelTitle
        self.selectedReasoningEffort = selectedReasoningEffort
        self.onFastModeTapped = onFastModeTapped
        self.onInformationalControlTapped = onInformationalControlTapped
        self.onSelectReasoningEffort = onSelectReasoningEffort
        self.onSelectModel = onSelectModel
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            controls(
                showsModelName: true,
                showsReasoningEffortName: true
            )

            controls(
                showsModelName: true,
                showsReasoningEffortName: false
            )

            controls(
                showsModelName: false,
                showsReasoningEffortName: false
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func controls(
        showsModelName: Bool,
        showsReasoningEffortName: Bool
    ) -> some View {
        HStack(spacing: 4) {
            modelControl(showsName: showsModelName)

            if showsFastMode {
                fastModeControl
            }

            if isReasoningEffortControlVisible {
                reasoningEffortControl(showsName: showsReasoningEffortName)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func modelControl(showsName: Bool) -> some View {
        switch interactionMode {
        case .editable:
            ModelPicker(
                agentType: agentType,
                allowsAgentSwitching: allowsAgentSwitching,
                allowedModels: allowedModels,
                selectedModel: selectedModel,
                showsName: showsName,
                selectedModelTitle: selectedModelTitle,
                onSelect: onSelectModel
            )
            .equatable()
            .accessibilityIdentifier(
                ModelConfigurationControl.model.accessibilityIdentifier
            )
        case .readOnlyInformational:
            Button {
                onInformationalControlTapped(.model)
            } label: {
                ModelControlLabel(
                    agentType: displayedModelAgentType,
                    title: displayedModelName,
                    showsName: showsName
                )
            }
            .buttonStyle(.spring)
            .accessibilityLabel("Model")
            .accessibilityValue(displayedModelName)
            .accessibilityHint(readOnlyAccessibilityHint)
            .accessibilityIdentifier(
                ModelConfigurationControl.model.accessibilityIdentifier
            )
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder
    private var fastModeControl: some View {
        switch interactionMode {
        case .editable:
            Button(action: onFastModeTapped) {
                fastModeLabel
            }
            .buttonStyle(.spring)
            .disabled(isDisabledDuringAction(.fastMode))
            .accessibilityLabel("Fast mode")
            .accessibilityValue(displayedFastModeName)
            .accessibilityIdentifier(
                ModelConfigurationControl.fastMode.accessibilityIdentifier
            )
        case .readOnlyInformational:
            Button {
                onInformationalControlTapped(.fastMode)
            } label: {
                fastModeLabel
            }
            .buttonStyle(.spring)
            .accessibilityLabel("Fast mode")
            .accessibilityValue(displayedFastModeName)
            .accessibilityHint(readOnlyAccessibilityHint)
            .accessibilityIdentifier(
                ModelConfigurationControl.fastMode.accessibilityIdentifier
            )
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder
    private func reasoningEffortControl(showsName: Bool) -> some View {
        switch interactionMode {
        case .editable:
            ReasoningEffortControl(
                availableEfforts: availableReasoningEfforts,
                selectedEffort: selectedReasoningEffort,
                isDisabled: isDisabledDuringAction(.reasoningEffort),
                showsName: showsName,
                onSelect: onSelectReasoningEffort
            )
            .accessibilityIdentifier(
                ModelConfigurationControl.reasoningEffort.accessibilityIdentifier
            )
        case .readOnlyInformational:
            Button {
                onInformationalControlTapped(.reasoningEffort)
            } label: {
                ReasoningEffortLabel(
                    effort: selectedReasoningEffort,
                    showsDefaultTitle: true,
                    showsName: showsName
                )
            }
            .buttonStyle(.spring)
            .accessibilityLabel("Reasoning effort")
            .accessibilityValue(displayedReasoningEffortName)
            .accessibilityHint(readOnlyAccessibilityHint)
            .accessibilityIdentifier(
                ModelConfigurationControl.reasoningEffort.accessibilityIdentifier
            )
        case .hidden:
            EmptyView()
        }
    }

    private var fastModeLabel: some View {
        Label {
            Text("Fast mode")
        } icon: {
            LucideIcon(Lucide.zap, style: .small)
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(
            .theme(isFastModeEnabled ? .accent : .textSecondary)
        )
        .padding(8)
        .background(
            Color.theme(.highlight)
                .opacity(isFastModeEnabled ? 1 : 0),
            in: .circle
        )
        .animation(.interactiveSpring, value: isFastModeEnabled)
    }

    var displayedModelAgentType: Session.AgentType {
        selectedModel.agentType ?? agentType
    }

    var displayedModelName: String {
        selectedModelTitle
            ?? (
                selectedModel.rawValue.isEmpty
                    ? "Default"
                    : selectedModel.displayName
            )
    }

    var displayedReasoningEffortName: String {
        selectedReasoningEffort?.displayName ?? "Default"
    }

    var displayedFastModeName: String {
        isFastModeEnabled ? "On" : "Off"
    }

    var isReasoningEffortControlVisible: Bool {
        interactionMode == .readOnlyInformational
            || !availableReasoningEfforts.isEmpty
    }

    func isDisabledDuringAction(
        _ control: ModelConfigurationControl
    ) -> Bool {
        guard interactionMode == .editable else {
            return false
        }
        switch control {
        case .reasoningEffort, .fastMode:
            return isFastModeButtonDisabled
        case .model:
            return false
        }
    }

    var readOnlyAccessibilityHint: String {
        "Double-tap to learn why this setting can’t be changed."
    }
}

public struct ModelMenu<SourceLabel: View>: View {
    let agentType: Session.AgentType
    let allowsAgentSwitching: Bool
    let allowedModels: Set<Session.Model>?
    let selectedModel: Session.Model
    let onSelect: @MainActor (Session.Model) -> Void
    let label: (Session.Model, Session.AgentType) -> SourceLabel

    public init(
        agentType: Session.AgentType,
        allowsAgentSwitching: Bool = false,
        allowedModels: Set<Session.Model>? = nil,
        selectedModel: Session.Model,
        onSelect: @escaping @MainActor (Session.Model) -> Void,
        @ViewBuilder label: @escaping (Session.Model, Session.AgentType) -> SourceLabel
    ) {
        self.agentType = agentType
        self.allowsAgentSwitching = allowsAgentSwitching
        self.allowedModels = allowedModels
        self.selectedModel = selectedModel
        self.onSelect = onSelect
        self.label = label
    }

    public var body: some View {
        Menu {
            modelSection(
                agentType: .claude,
                models: models(for: .claude),
                title: "Claude Code"
            )

            modelSection(
                agentType: .codex,
                models: models(for: .codex),
                title: "Codex"
            )
        } label: {
            label(
                selectedModel,
                selectedModel.agentType ?? agentType
            )
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Model")
        .accessibilityValue(selectedModel.displayName)
    }

    private func models(for sectionAgentType: Session.AgentType) -> [Session.Model] {
        var models = Session.Model.models(for: sectionAgentType)
        if let allowedModels {
            models = models.filter(allowedModels.contains)
        }
        if sectionAgentType == agentType, !models.contains(selectedModel) {
            models.insert(selectedModel, at: 0)
        }
        return models
    }

    private func allowsSelection(for sectionAgentType: Session.AgentType) -> Bool {
        allowsAgentSwitching || sectionAgentType == agentType
    }

    @ViewBuilder
    private func modelSection(
        agentType sectionAgentType: Session.AgentType,
        models: [Session.Model],
        title: String
    ) -> some View {
        Section {
            Picker(
                title,
                selection: Binding(
                    get: { selectedModel },
                    set: { onSelect($0) }
                )
            ) {
                ForEach(models, id: \.self) { model in
                    modelLabel(model.displayName, agentType: sectionAgentType)
                        .tag(model)
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
            .disabled(!allowsSelection(for: sectionAgentType))
        } header: {
            modelLabel(title, agentType: sectionAgentType)
                .foregroundStyle(.theme(.textSecondary))
        }
    }

    private func modelLabel(
        _ title: String,
        agentType: Session.AgentType
    ) -> some View {
        ModelControlLabel(agentType: agentType, title: title)
    }
}

public struct ModelPicker: Equatable, View {
    let agentType: Session.AgentType
    let allowsAgentSwitching: Bool
    let allowedModels: Set<Session.Model>?
    let selectedModel: Session.Model
    let showsName: Bool
    let selectedModelTitle: String?
    let onSelect: @MainActor (Session.Model) -> Void

    public init(
        agentType: Session.AgentType,
        allowsAgentSwitching: Bool = false,
        allowedModels: Set<Session.Model>? = nil,
        selectedModel: Session.Model,
        showsName: Bool = true,
        selectedModelTitle: String? = nil,
        onSelect: @escaping @MainActor (Session.Model) -> Void
    ) {
        self.agentType = agentType
        self.allowsAgentSwitching = allowsAgentSwitching
        self.allowedModels = allowedModels
        self.selectedModel = selectedModel
        self.showsName = showsName
        self.selectedModelTitle = selectedModelTitle
        self.onSelect = onSelect
    }

    // System menus reset their open scroll position when SwiftUI replaces equal content.
    // A recreated action closure is not a content change and must not trigger that replacement.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.agentType == rhs.agentType
            && lhs.allowsAgentSwitching == rhs.allowsAgentSwitching
            && lhs.allowedModels == rhs.allowedModels
            && lhs.selectedModel == rhs.selectedModel
            && lhs.showsName == rhs.showsName
            && lhs.selectedModelTitle == rhs.selectedModelTitle
    }

    public var body: some View {
        ModelMenu(
            agentType: agentType,
            allowsAgentSwitching: allowsAgentSwitching,
            allowedModels: allowedModels,
            selectedModel: selectedModel,
            onSelect: onSelect
        ) { model, agentType in
            modelLabel(
                selectedModelTitle ?? model.displayName,
                agentType: agentType
            )
        }
        .accessibilityValue(selectedModelTitle ?? selectedModel.displayName)
    }

    func allowsSelection(for sectionAgentType: Session.AgentType) -> Bool {
        allowsAgentSwitching || sectionAgentType == agentType
    }

    private func modelLabel(
        _ model: Session.Model,
        agentType: Session.AgentType
    ) -> some View {
        modelLabel(model.displayName, agentType: agentType)
    }

    private func modelLabel(
        _ title: String,
        agentType: Session.AgentType
    ) -> some View {
        ModelControlLabel(
            agentType: agentType,
            title: title,
            showsName: showsName
        )
    }
}

private struct ModelControlLabel: View {
    let agentType: Session.AgentType
    let title: String
    var showsName = true

    var body: some View {
        Group {
            if showsName {
                label
                    .labelStyle(.conductorExtraSmall)
            } else {
                label
                    .labelStyle(.iconOnly)
            }
        }
        .foregroundStyle(.theme(.textPrimary))
        .font(.theme(.small))
    }

    private var label: some View {
        Label {
            Text(title)
        } icon: {
            AgentIcon(
                agentType: agentType,
                size: ThemeFontStyle.small.size,
                relativeTo: ThemeFontStyle.small.textStyle
            )
        }
    }
}

#Preview {
    ModelAndFastModeControls(
        agentType: .codex,
        allowsAgentSwitching: true,
        availableReasoningEfforts: Session.Model.gpt_5_6_sol.availableCodexReasoningEfforts,
        isFastModeEnabled: true,
        selectedModel: .gpt_5_6_sol,
        selectedReasoningEffort: .ultra,
        onFastModeTapped: { },
        onSelectReasoningEffort: { _ in },
        onSelectModel: { _ in }
    )
    .padding()
    .background(.theme(.background))
    .preferredColorScheme(.dark)
}
