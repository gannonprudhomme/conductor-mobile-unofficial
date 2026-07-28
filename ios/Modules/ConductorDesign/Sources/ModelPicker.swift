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

public struct ModelAndFastModeControls: View {
    let agentType: Session.AgentType
    let allowsAgentSwitching: Bool
    let allowedModels: Set<Session.Model>?
    let availableReasoningEfforts: [Session.ReasoningEffort]
    let isFastModeEnabled: Bool
    let isFastModeButtonDisabled: Bool
    let showsFastMode: Bool
    let selectedModel: Session.Model
    let selectedReasoningEffort: Session.ReasoningEffort?
    let onFastModeTapped: @MainActor () -> Void
    let onSelectReasoningEffort: @MainActor (Session.ReasoningEffort) -> Void
    let onSelectModel: @MainActor (Session.Model) -> Void

    public init(
        agentType: Session.AgentType,
        allowsAgentSwitching: Bool = false,
        allowedModels: Set<Session.Model>? = nil,
        availableReasoningEfforts: [Session.ReasoningEffort],
        isFastModeEnabled: Bool,
        isFastModeButtonDisabled: Bool = false,
        showsFastMode: Bool = true,
        selectedModel: Session.Model,
        selectedReasoningEffort: Session.ReasoningEffort?,
        onFastModeTapped: @escaping @MainActor () -> Void,
        onSelectReasoningEffort: @escaping @MainActor (Session.ReasoningEffort) -> Void,
        onSelectModel: @escaping @MainActor (Session.Model) -> Void
    ) {
        self.agentType = agentType
        self.allowsAgentSwitching = allowsAgentSwitching
        self.allowedModels = allowedModels
        self.availableReasoningEfforts = availableReasoningEfforts
        self.isFastModeEnabled = isFastModeEnabled
        self.isFastModeButtonDisabled = isFastModeButtonDisabled
        self.showsFastMode = showsFastMode
        self.selectedModel = selectedModel
        self.selectedReasoningEffort = selectedReasoningEffort
        self.onFastModeTapped = onFastModeTapped
        self.onSelectReasoningEffort = onSelectReasoningEffort
        self.onSelectModel = onSelectModel
    }

    public var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ModelPicker(
                    agentType: agentType,
                    allowsAgentSwitching: allowsAgentSwitching,
                    allowedModels: allowedModels,
                    selectedModel: selectedModel,
                    onSelect: onSelectModel
                )
                .equatable()

                if showsFastMode {
                    Button(action: onFastModeTapped) {
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
                    .buttonStyle(.spring)
                    .disabled(isFastModeButtonDisabled)
                    .accessibilityLabel("Fast mode")
                    .accessibilityValue(isFastModeEnabled ? "On" : "Off")
                }

                if !availableReasoningEfforts.isEmpty {
                    ReasoningEffortControl(
                        availableEfforts: availableReasoningEfforts,
                        selectedEffort: selectedReasoningEffort,
                        isDisabled: isFastModeButtonDisabled,
                        onSelect: onSelectReasoningEffort
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .defaultScrollAnchor(.leading)
        .fixedSize(horizontal: false, vertical: true)
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
        Label {
            Text(title)
        } icon: {
            AgentIcon(
                agentType: agentType,
                size: ThemeFontStyle.small.size,
                relativeTo: ThemeFontStyle.small.textStyle
            )
        }
        .labelStyle(.conductorExtraSmall)
        .foregroundStyle(.theme(.textPrimary))
        .font(.theme(.small))
    }
}

public struct ModelPicker: Equatable, View {
    let agentType: Session.AgentType
    let allowsAgentSwitching: Bool
    let allowedModels: Set<Session.Model>?
    let selectedModel: Session.Model
    let onSelect: @MainActor (Session.Model) -> Void

    public init(
        agentType: Session.AgentType,
        allowsAgentSwitching: Bool = false,
        allowedModels: Set<Session.Model>? = nil,
        selectedModel: Session.Model,
        onSelect: @escaping @MainActor (Session.Model) -> Void
    ) {
        self.agentType = agentType
        self.allowsAgentSwitching = allowsAgentSwitching
        self.allowedModels = allowedModels
        self.selectedModel = selectedModel
        self.onSelect = onSelect
    }

    // System menus reset their open scroll position when SwiftUI replaces equal content.
    // A recreated action closure is not a content change and must not trigger that replacement.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.agentType == rhs.agentType
            && lhs.allowsAgentSwitching == rhs.allowsAgentSwitching
            && lhs.allowedModels == rhs.allowedModels
            && lhs.selectedModel == rhs.selectedModel
    }

    public var body: some View {
        ModelMenu(
            agentType: agentType,
            allowsAgentSwitching: allowsAgentSwitching,
            allowedModels: allowedModels,
            selectedModel: selectedModel,
            onSelect: onSelect
        ) { model, agentType in
            modelLabel(model, agentType: agentType)
        }
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
        Label {
            Text(title)
        } icon: {
            AgentIcon(
                agentType: agentType,
                size: ThemeFontStyle.small.size,
                relativeTo: ThemeFontStyle.small.textStyle
            )
        }
        .labelStyle(.conductorExtraSmall)
        .foregroundStyle(.theme(.textPrimary))
        .font(.theme(.small))
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
