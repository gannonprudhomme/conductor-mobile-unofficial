//
//  ChatTextField.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/10/26.
//

import ConductorDesign
import LucideIcons
import SharedConductorData
import SwiftUI

struct ChatTextField: View {
    @FocusState var isFocused: Bool

    @Binding var text: String
    @Binding var selectedModel: Session.Model
    let selectedReasoningEffort: Session.ReasoningEffort?
    let availableReasoningEfforts: [Session.ReasoningEffort]
    let agentType: Session.AgentType
    let allowsAgentSwitching: Bool
    let contextWindowUsage: ContextWindowUsage?
    let allowsQueue: Bool
    let showsConfigurationControls: Bool
    let isFastModeEnabled: Bool
    let isEditingQueuedMessage: Bool
    let isSendInFlight: Bool
    let isStopInFlight: Bool
    let isWorking: Bool
    let shouldFocusOnAppear: Bool
    let onFastModeTapped: @MainActor () -> Void
    let onCancelEditingTapped: @MainActor () -> Void
    let onSelectReasoningEffort: @MainActor (Session.ReasoningEffort) -> Void
    let onSendTapped: @MainActor () -> Void
    let onQueueTapped: @MainActor () -> Void
    let onStopTapped: @MainActor () -> Void

    init(
        text: Binding<String>,
        agentType: Session.AgentType,
        allowsAgentSwitching: Bool,
        contextWindowUsage: ContextWindowUsage? = nil,
        allowsQueue: Bool = true,
        showsConfigurationControls: Bool = true,
        isFastModeEnabled: Bool,
        isEditingQueuedMessage: Bool = false,
        isSendInFlight: Bool,
        isStopInFlight: Bool,
        isWorking: Bool,
        selectedModel: Binding<Session.Model>,
        selectedReasoningEffort: Session.ReasoningEffort?,
        availableReasoningEfforts: [Session.ReasoningEffort],
        shouldFocusOnAppear: Bool = false,
        onFastModeTapped: @escaping @MainActor () -> Void,
        onCancelEditingTapped: @escaping @MainActor () -> Void = { },
        onSelectReasoningEffort: @escaping @MainActor (Session.ReasoningEffort) -> Void,
        onSendTapped: @escaping @MainActor () -> Void,
        onQueueTapped: @escaping @MainActor () -> Void = { },
        onStopTapped: @escaping @MainActor () -> Void
    ) {
        self._text = text
        self.agentType = agentType
        self.allowsAgentSwitching = allowsAgentSwitching
        self.contextWindowUsage = contextWindowUsage
        self.allowsQueue = allowsQueue
        self.showsConfigurationControls = showsConfigurationControls
        self.isFastModeEnabled = isFastModeEnabled
        self.isEditingQueuedMessage = isEditingQueuedMessage
        self.isSendInFlight = isSendInFlight
        self.isStopInFlight = isStopInFlight
        self.isWorking = isWorking
        self._selectedModel = selectedModel
        self.selectedReasoningEffort = selectedReasoningEffort
        self.availableReasoningEfforts = availableReasoningEfforts
        self.shouldFocusOnAppear = shouldFocusOnAppear
        self.onFastModeTapped = onFastModeTapped
        self.onCancelEditingTapped = onCancelEditingTapped
        self.onSelectReasoningEffort = onSelectReasoningEffort
        self.onSendTapped = onSendTapped
        self.onQueueTapped = onQueueTapped
        self.onStopTapped = onStopTapped
    }

    var body: some View {
        VStack(spacing: 12) {
            if isEditingQueuedMessage {
                editingHeader
            }

            textField

            bottomRowButtons
        }
        .animation(.default, value: isFocused)
        .padding(EdgeInsets(vertical: 12, horizontal: 16))
        .glassEffect(
            .clear
                .tint(.theme(.background).opacity(0.925)),
            in: .rect(cornerRadius: 26)
        )
        .padding(EdgeInsets(vertical: 8, horizontal: 8))
        .task {
            guard shouldFocusOnAppear else {
                return
            }
            isFocused = true
        }
        .onChange(of: isEditingQueuedMessage) { _, isEditing in
            if isEditing {
                isFocused = true
            }
        }
    }

    private var editingHeader: some View {
        HStack(spacing: 8) {
            Text("Editing queued message")
                .font(.theme(.small))
                .foregroundStyle(.theme(.textSecondary))
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Cancel", action: onCancelEditingTapped)
                .font(.theme(.small))
                .foregroundStyle(.theme(.accent))
                .disabled(isAnyActionInFlight)
        }
        .accessibilityElement(children: .contain)
    }

    private var textField: some View {
        TextField(
            "Message",
            text: $text,
            prompt: Text("Message")
                .foregroundStyle(.theme(.textSecondary)),
            axis: .vertical
        )
        .lineLimit(1...6)
        .focused($isFocused)
        .textFieldStyle(.plain)
        .font(.theme(.body))
        .foregroundStyle(.theme(.textPrimary))
        .tint(.theme(.accent))
    }

    private var bottomRowButtons: some View {
        HStack(spacing: 8) {
            Group {
                if showsConfigurationControls {
                    ModelAndFastModeControls(
                        agentType: agentType,
                        allowsAgentSwitching: allowsAgentSwitching,
                        availableReasoningEfforts: availableReasoningEfforts,
                        isFastModeEnabled: isFastModeEnabled,
                        isFastModeButtonDisabled: isAnyActionInFlight,
                        selectedModel: selectedModel,
                        selectedReasoningEffort: selectedReasoningEffort,
                        onFastModeTapped: onFastModeTapped,
                        onSelectReasoningEffort: onSelectReasoningEffort,
                        onSelectModel: { selectedModel = $0 }
                    )
                } else {
                    Text(selectedModel.rawValue)
                        .font(.theme(.small))
                        .foregroundStyle(.theme(.textSecondary))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if let contextWindowUsage {
                    ContextWindowUsageGauge(usage: contextWindowUsage)
                }

                if !isEditingQueuedMessage && (isWorking || isStopInFlight) {
                    StopButton(
                        isEnabled: !isAnyActionInFlight,
                        isInFlight: isStopInFlight,
                        action: onStopTapped
                    )
                }

                if isEditingQueuedMessage
                    || (!isWorking && !isStopInFlight)
                    || hasSendableText
                    || isSendInFlight {
                    SendButton(
                        isEditingQueuedMessage: isEditingQueuedMessage,
                        allowsQueue: allowsQueue,
                        isEnabled: hasSendableText && !isAnyActionInFlight,
                        isInFlight: isSendInFlight,
                        primaryAction: onSendTapped,
                        queueAction: onQueueTapped
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.default, value: hasSendableText)
        .animation(.default, value: isWorking)
    }

    private var hasSendableText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isAnyActionInFlight: Bool {
        isSendInFlight || isStopInFlight
    }

    private struct SendButton: View {
        let isEditingQueuedMessage: Bool
        let allowsQueue: Bool
        let isEnabled: Bool
        let isInFlight: Bool
        let primaryAction: @MainActor () -> Void
        let queueAction: @MainActor () -> Void

        var body: some View {
            Group {
                if isEditingQueuedMessage || !isEnabled || !allowsQueue {
                    Button(action: primaryAction) {
                        label
                    }
                } else {
                    Menu {
                        Button(action: primaryAction) {
                            Label {
                                Text("Steer")
                            } icon: {
                                ColoredMenuImage(Lucide.arrowUp)
                            }
                        }

                        Button(action: queueAction) {
                            Label {
                                Text("Queue")
                            } icon: {
                                ColoredMenuImage(Lucide.cornerDownLeft)
                            }
                        }
                    } label: {
                        label
                    } primaryAction: {
                        primaryAction()
                    }
                }
            }
            .disabled(!isEnabled)
            .accessibilityIdentifier("chat.send")
            .glassEffect(
                .regular
                    .tint(Color.theme(.foreground).opacity(isEnabled ? 1 : 0.5))
                    .interactive(isEnabled)
            )
            .animation(.default, value: isInFlight)
            .sensoryFeedback(.selection, trigger: isInFlight) { _, isInFlight in
                isInFlight
            }
        }

        private var label: some View {
            Label {
                Text(isEditingQueuedMessage ? "Save queued message" : "Send message")
            } icon: {
                if isInFlight {
                    ProgressView()
                        .progressViewStyle(.network)
                        .tint(.theme(.background))
                } else {
                    LucideIcon(
                        isEditingQueuedMessage ? Lucide.check : Lucide.arrowUp,
                        style: .body
                    )
                }
            }
            .labelStyle(.iconOnly)
            .font(.theme(.body))
            .foregroundStyle(.theme(.background))
            .tint(.theme(.background))
            .padding(8)
        }
    }

    private struct StopButton: View {
        @ScaledMetric(relativeTo: ThemeFontStyle.body.textStyle)
        private var iconSize = ThemeFontStyle.body.size

        let isEnabled: Bool
        let isInFlight: Bool
        let action: @MainActor () -> Void

        var body: some View {
            Button(action: action) {
                Label {
                    Text("Stop agent")
                } icon: {
                    if isInFlight {
                        ProgressView()
                            .progressViewStyle(.network)
                            .tint(.theme(.textPrimary))
                    } else {
                        let rectSize = iconSize / 1.5
                        Rectangle()
                            .fill(Color.theme(.textPrimary))
                            .frame(width: rectSize, height: rectSize)
                            .frame(width: iconSize, height: iconSize)
                            .contentTransition(.opacity)
                    }
                }
                .labelStyle(.iconOnly)
                .font(.theme(.body))
                .foregroundStyle(.theme(.textPrimary))
                .tint(.theme(.textPrimary))
                .padding(8)
            }
            .disabled(!isEnabled)
            .glassEffect(
                .regular
                    .tint(Color.theme(.foreground).opacity(0.05))
                    .interactive(isEnabled)
            )
            .animation(.default, value: isInFlight)
            .sensoryFeedback(.selection, trigger: isInFlight) { _, isInFlight in
                isInFlight
            }
        }
    }

    private struct ContextWindowUsageGauge: View {
        @ScaledMetric(relativeTo: ThemeFontStyle.body.textStyle)
        private var size = 18.0

        let usage: ContextWindowUsage

        var body: some View {
            ZStack {
                Circle()
                    .stroke(
                        Color.theme(.textSecondary).opacity(0.3),
                        lineWidth: 2.5
                    )

                if usage.fraction > 0 {
                    Circle()
                        .trim(from: 0, to: CGFloat(usage.fraction))
                        .stroke(
                            Color.theme(.textSecondary),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: size, height: size)
            .padding(EdgeInsets(vertical: 8, horizontal: 4))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Context window usage")
            .accessibilityValue(
                "\(usage.percentage) percent used, "
                    + "\(usage.usedTokens.formatted()) of \(usage.tokenLimit.formatted()) tokens"
            )
            .accessibilityIdentifier("chat.contextUsage")
            .animation(.smooth(duration: 0.25), value: usage.fraction)
        }
    }
}

#Preview {
    @Previewable @State var isFastModeEnabled = true
    @Previewable @State var text = ""
    @Previewable @State var selectedModel = Session.Model.gpt_5_6_sol

    ScrollView {
        LazyVStack(spacing: 4) {
            ForEach(0..<10) { _ in
                Text("this is a really really really long string I guess")
            }
        }
    }
    .scrollContentBackground(.hidden)
    .background(.theme(.background))
    .safeAreaBar(edge: .bottom) {
        ChatTextField(
            text: $text,
            agentType: .codex,
            allowsAgentSwitching: true,
            contextWindowUsage: ContextWindowUsage(
                usedTokens: 137_000,
                tokenLimit: 272_000
            ),
            isFastModeEnabled: isFastModeEnabled,
            isSendInFlight: false,
            isStopInFlight: false,
            isWorking: true,
            selectedModel: $selectedModel,
            selectedReasoningEffort: .ultra,
            availableReasoningEfforts: selectedModel.availableCodexReasoningEfforts,
            onFastModeTapped: { isFastModeEnabled.toggle() },
            onSelectReasoningEffort: { _ in },
            onSendTapped: { },
            onStopTapped: { }
        )
        .preferredColorScheme(.dark)
    }
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .preferredColorScheme(.dark)
}
