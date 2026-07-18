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
    let agentType: Session.AgentType
    let isFastModeEnabled: Bool
    let isSendInFlight: Bool
    let isStopInFlight: Bool
    let isWorking: Bool
    let shouldFocusOnAppear: Bool
    let onFastModeTapped: @MainActor () -> Void
    let onSendTapped: @MainActor () -> Void
    let onStopTapped: @MainActor () -> Void

    init(
        text: Binding<String>,
        agentType: Session.AgentType,
        isFastModeEnabled: Bool,
        isSendInFlight: Bool,
        isStopInFlight: Bool,
        isWorking: Bool,
        selectedModel: Binding<Session.Model>,
        shouldFocusOnAppear: Bool = false,
        onFastModeTapped: @escaping @MainActor () -> Void,
        onSendTapped: @escaping @MainActor () -> Void,
        onStopTapped: @escaping @MainActor () -> Void
    ) {
        self._text = text
        self.agentType = agentType
        self.isFastModeEnabled = isFastModeEnabled
        self.isSendInFlight = isSendInFlight
        self.isStopInFlight = isStopInFlight
        self.isWorking = isWorking
        self._selectedModel = selectedModel
        self.shouldFocusOnAppear = shouldFocusOnAppear
        self.onFastModeTapped = onFastModeTapped
        self.onSendTapped = onSendTapped
        self.onStopTapped = onStopTapped
    }

    var body: some View {
        VStack(spacing: 12) {
            textField

            bottomRowButtons
        }
        .animation(.default, value: isFocused)
        .padding(EdgeInsets(vertical: 12, horizontal: 16))
        .glassEffect(
            .clear
                .tint(.theme(.background).opacity(0.75)),
            in: .rect(cornerRadius: 26)
        )
        .padding(EdgeInsets(vertical: 8, horizontal: 8))
        .onAppear {
            guard shouldFocusOnAppear else {
                return
            }

            isFocused = true
        }
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
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ChatModelPicker(
                        agentType: agentType,
                        selectedModel: selectedModel,
                        onSelect: { selectedModel = $0 }
                    )
                    .equatable()

                    fastModeButton
                }
                .frame(maxHeight: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .defaultScrollAnchor(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if isWorking || isStopInFlight {
                    StopButton(
                        isEnabled: !isAnyActionInFlight,
                        isInFlight: isStopInFlight,
                        action: onStopTapped
                    )
                }

                if (!isWorking && !isStopInFlight) || hasSendableText || isSendInFlight {
                    SendButton(
                        isEnabled: hasSendableText && !isAnyActionInFlight,
                        isInFlight: isSendInFlight,
                        action: onSendTapped
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

    private var fastModeButton: some View {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Color.theme(.highlight)
                    .opacity(isFastModeEnabled ? 1 : 0),
                in: .circle
            )
            .animation(.interactiveSpring, value: isFastModeEnabled)
        }
        .aspectRatio(1, contentMode: .fit)
        .buttonStyle(.spring)
        .disabled(isAnyActionInFlight)
        .accessibilityLabel("Fast mode")
        .accessibilityValue(isFastModeEnabled ? "On" : "Off")
    }

    private struct SendButton: View {
        let isEnabled: Bool
        let isInFlight: Bool
        let action: @MainActor () -> Void

        var body: some View {
            Button(action: action) {
                Label {
                    Text("Send message")
                } icon: {
                    if isInFlight {
                        ProgressView()
                            .progressViewStyle(.network)
                            .tint(.theme(.background))
                    } else {
                        LucideIcon(Lucide.arrowUp, style: .body)
                    }
                }
                .labelStyle(.iconOnly)
                .font(.theme(.body))
                .foregroundStyle(.theme(.background))
                .tint(.theme(.background))
                .padding(8)
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
            isFastModeEnabled: isFastModeEnabled,
            isSendInFlight: false,
            isStopInFlight: false,
            isWorking: true,
            selectedModel: $selectedModel,
            onFastModeTapped: { isFastModeEnabled.toggle() },
            onSendTapped: { },
            onStopTapped: { }
        )
        .preferredColorScheme(.dark)
    }
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .preferredColorScheme(.dark)
}
