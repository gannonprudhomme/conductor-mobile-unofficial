//
//  ChatTextField.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/10/26.
//

import SharedConductorData
import ConductorDesign
import LucideIcons
import SwiftUI

struct ChatTextField: View {
    @FocusState var isFocused: Bool

    @Binding var text: String
    let isSendInFlight: Bool
    let isStopInFlight: Bool
    let isWorking: Bool
    let onSendTapped: @MainActor () -> Void
    let onStopTapped: @MainActor () -> Void

    init(
        text: Binding<String>,
        isSendInFlight: Bool,
        isStopInFlight: Bool,
        isWorking: Bool,
        onSendTapped: @escaping @MainActor () -> Void,
        onStopTapped: @escaping @MainActor () -> Void
    ) {
        self._text = text
        self.isSendInFlight = isSendInFlight
        self.isStopInFlight = isStopInFlight
        self.isWorking = isWorking
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
    }

    private var bottomRowButtons: some View {
        HStack(spacing: 8) {
            modelPicker
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if isWorking {
                    StopButton(
                        isEnabled: !isAnyActionInFlight,
                        isInFlight: isStopInFlight,
                        action: onStopTapped
                    )
                }

                if !isWorking || hasSendableText {
                    SendButton(
                        isEnabled: hasSendableText && !isAnyActionInFlight,
                        isInFlight: isSendInFlight,
                        action: onSendTapped
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.default, value: hasSendableText)
        .animation(.default, value: isWorking)
    }

    private var hasSendableText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isAnyActionInFlight: Bool {
        isSendInFlight || isStopInFlight
    }

    private var modelPicker: some View {
        Label {
            Text("GPT-5.6 Sol")
        } icon: {
            AgentIcon(
                agentType: Session.AgentType.codex,
                size: ThemeFontStyle.small.size,
                relativeTo: ThemeFontStyle.small.textStyle
            )
        }
        .labelStyle(.conductorExtraSmall)
        .foregroundStyle(.theme(.textPrimary))
        .font(.theme(.small))
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
                        // Intentionally use the platform spinner for this compact button.
                        ProgressView()
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
            .glassEffect(
                .regular
                    .tint(Color.theme(.foreground).opacity(isEnabled ? 1 : 0.5))
                    .interactive(isEnabled)
            )
            .animation(.default, value: isInFlight)
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
                        // Intentionally use the platform spinner for this compact button.
                        ProgressView()
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
        }
    }
}

#Preview {
    @Previewable @State var text = ""

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
            isSendInFlight: false,
            isStopInFlight: false,
            isWorking: true,
            onSendTapped: { },
            onStopTapped: { }
        )
        .preferredColorScheme(.dark)
    }
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .preferredColorScheme(.dark)
}
