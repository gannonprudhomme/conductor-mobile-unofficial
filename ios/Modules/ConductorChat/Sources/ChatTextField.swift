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
    let onSendTapped: @MainActor () -> Void

    init(
        text: Binding<String>,
        isSendInFlight: Bool,
        onSendTapped: @escaping @MainActor () -> Void
    ) {
        self._text = text
        self.isSendInFlight = isSendInFlight
        self.onSendTapped = onSendTapped
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

            sendButton
        }
        .frame(maxWidth: .infinity)
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

    private var isSendButtonEnabled: Bool {
        let hasNonWhitespaceCharacters = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return hasNonWhitespaceCharacters && !isSendInFlight
    }

    private var sendButton: some View {
        SendButton(onTap: onSendTapped)
            .disabled(!isSendButtonEnabled)
    }

    private struct SendButton: View {
        @Environment(\.isEnabled) var isEnabled
        let onTap: @MainActor () -> Void

        var body: some View {
            Button {
                onTap()
            } label: {
                Label {
                    Text("Send message")
                } icon: {
                    LucideIcon(Lucide.arrowUp, style: .body)
                        .foregroundStyle(.theme(.background))
                }
                .labelStyle(.iconOnly)
                .font(.theme(.body))
                .padding(8)
            }
            .glassEffect(
                .regular
                    .tint(.theme(.foreground).opacity(isEnabled ? 1 : 0.5))
                    .interactive(isEnabled)
            )
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
        ChatTextField(text: $text, isSendInFlight: false) { }
        .preferredColorScheme(.dark)
    }
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .preferredColorScheme(.dark)
}
