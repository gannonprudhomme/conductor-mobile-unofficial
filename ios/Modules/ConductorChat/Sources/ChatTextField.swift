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
            .regular
                .tint(.theme(.background).opacity(0.8)),
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

            SendStopButton(
                text: text,
                isSendInFlight: isSendInFlight,
                isStopInFlight: isStopInFlight,
                isWorking: isWorking,
                onSendTapped: onSendTapped,
                onStopTapped: onStopTapped
            )
        }
        .frame(maxWidth: .infinity)
        .animation(.default, value: isWorking)
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

    private struct SendStopButton: View {
        @ScaledMetric(relativeTo: .body) private var primaryActionIconSize = ThemeFontStyle.body.size

        let text: String
        let isSendInFlight: Bool
        let isStopInFlight: Bool
        let isWorking: Bool
        let onSendTapped: @MainActor () -> Void
        let onStopTapped: @MainActor () -> Void

        var body: some View {
            Button(action: primaryAction) {
                Label {
                    Text(isWorking ? "Stop agent" : "Send message")
                } icon: {
                    if isPrimaryActionInFlight {
                        // Intentionally use the platform spinner for this compact button.
                        ProgressView()
                    } else if isWorking {
                        let rectSize = primaryActionIconSize / 1.5
                        Rectangle()
                            .fill(Color.theme(.textPrimary))
                            .frame(width: rectSize, height: rectSize)
                            .frame(width: primaryActionIconSize, height: primaryActionIconSize)
                            .contentTransition(.opacity)
                    } else {
                        LucideIcon(Lucide.arrowUp, style: .body)
                            .contentTransition(.opacity)
                    }
                }
                .labelStyle(.iconOnly)
                .font(.theme(.body))
                .foregroundStyle(primaryActionForegroundStyle)
                .tint(primaryActionForegroundStyle)
                .padding(8)
            }
            .disabled(!isPrimaryActionEnabled)
            .glassEffect(
                isWorking
                    ? .clear
                        .tint(Color.clear)
                        .interactive(isPrimaryActionEnabled)
                    : .regular
                        .tint(primaryActionTint)
                        .interactive(isPrimaryActionEnabled)
            )
            .overlay {
                if isWorking {
                    Circle()
                        .strokeBorder(
                            Color.theme(.textPrimary),
                            lineWidth: 1
                        )
                }
            }
            .animation(.default, value: isWorking)
            .animation(.default, value: isPrimaryActionInFlight)
        }

        private var hasSendableText: Bool {
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        private var isPrimaryActionEnabled: Bool {
            !isPrimaryActionInFlight && (isWorking || hasSendableText)
        }

        private var isPrimaryActionInFlight: Bool {
            isSendInFlight || isStopInFlight
        }

        private var primaryAction: @MainActor () -> Void {
            isWorking ? onStopTapped : onSendTapped
        }

        private var primaryActionForegroundStyle: Color {
            if isWorking {
                Color.theme(.textPrimary)
            } else {
                Color.theme(.background)
            }
        }

        private var primaryActionTint: Color {
            if isWorking {
                Color.clear
            } else {
                Color.theme(.foreground).opacity(isPrimaryActionEnabled ? 1 : 0.5)
            }
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
