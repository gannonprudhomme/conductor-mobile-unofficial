//
//  ChatModelPicker.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/13/26.
//

import ConductorDesign
import ConductorMobileData
import SharedConductorData
import SwiftUI

struct ChatModelPicker: Equatable, View {
    let agentType: Session.AgentType
    let selectedModel: Session.Model
    let onSelect: @MainActor (Session.Model) -> Void

    // System menus reset their open scroll position when SwiftUI replaces equal content.
    // A recreated action closure is not a content change and must not trigger that replacement.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.agentType == rhs.agentType
            && lhs.selectedModel == rhs.selectedModel
    }

    var body: some View {
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
            modelLabel(selectedModel, agentType: agentType)
                .frame(maxHeight: .infinity)
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Model")
        .accessibilityValue(selectedModel.displayName)
    }

    private func models(for sectionAgentType: Session.AgentType) -> [Session.Model] {
        var models = Session.Model.models(for: sectionAgentType)
        if sectionAgentType == agentType, !models.contains(selectedModel) {
            models.insert(selectedModel, at: 0)
        }
        return models
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
                    modelLabel(model, agentType: sectionAgentType)
                        .tag(model)
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
            .disabled(sectionAgentType != agentType)
        } header: {
            modelLabel(title, agentType: sectionAgentType)
                .foregroundStyle(.theme(.textSecondary))
        }
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
    ChatModelPicker(
        agentType: .codex,
        selectedModel: .gpt_5_6_sol,
        onSelect: { _ in }
    )
    .padding()
    .background(.theme(.background))
    .preferredColorScheme(.dark)
}
