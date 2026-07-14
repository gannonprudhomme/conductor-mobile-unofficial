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
    let session: Session
    let agentOptions: Session.AgentOptions
    let isSendInFlight: Bool
    let isSessionOptionsUpdateInFlight: Bool
    let isStopInFlight: Bool
    let isWorking: Bool
    let onFastModeTapped: @MainActor () -> Void
    let onReasoningEffortSelected: @MainActor (Session.ReasoningEffort) -> Void
    let onSendTapped: @MainActor () -> Void
    let onStopTapped: @MainActor () -> Void

    init(
        text: Binding<String>,
        session: Session,
        agentOptions: Session.AgentOptions,
        isSendInFlight: Bool,
        isSessionOptionsUpdateInFlight: Bool,
        isStopInFlight: Bool,
        isWorking: Bool,
        onFastModeTapped: @escaping @MainActor () -> Void,
        onReasoningEffortSelected: @escaping @MainActor (Session.ReasoningEffort) -> Void,
        onSendTapped: @escaping @MainActor () -> Void,
        onStopTapped: @escaping @MainActor () -> Void
    ) {
        self._text = text
        self.session = session
        self.agentOptions = agentOptions
        self.isSendInFlight = isSendInFlight
        self.isSessionOptionsUpdateInFlight = isSessionOptionsUpdateInFlight
        self.isStopInFlight = isStopInFlight
        self.isWorking = isWorking
        self.onFastModeTapped = onFastModeTapped
        self.onReasoningEffortSelected = onReasoningEffortSelected
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
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    modelLabel

                    fastModeButton

                    if !session.availableReasoningEfforts.isEmpty {
                        reasoningEffortButton
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .defaultScrollAnchor(.leading)
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

    private var modelLabel: some View {
        Label {
            Text(session.displayModelName)
        } icon: {
            AgentIcon(
                agentType: session.agentType,
                size: ThemeFontStyle.small.size,
                relativeTo: ThemeFontStyle.small.textStyle
            )
        }
        .labelStyle(.conductorExtraSmall)
        .foregroundStyle(.theme(.textPrimary))
        .font(.theme(.small))
        .fixedSize()
    }

    private var fastModeButton: some View {
        Button(action: onFastModeTapped) {
            HStack(spacing: 6) {
                LucideIcon(Lucide.zap, style: .small)

                if agentOptions.fastMode {
                    Text("Fast")
                        .font(.theme(.small))
                }
            }
            .foregroundStyle(
                .theme(agentOptions.fastMode ? .accent : .textSecondary)
            )
            .padding(EdgeInsets(vertical: 6, horizontal: 8))
            .background(
                agentOptions.fastMode ? .theme(.highlight) : Color.clear,
                in: .capsule
            )
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(isSessionOptionsUpdateInFlight)
        .accessibilityLabel("Fast mode")
        .accessibilityValue(agentOptions.fastMode ? "On" : "Off")
    }

    private var reasoningEffortButton: some View {
        Button(action: reasoningEffortButtonTapped) {
            HStack(spacing: 6) {
                ReasoningEffortIcon(
                    isSelected: agentOptions.reasoningEffort != .none
                )

                if agentOptions.reasoningEffort != .none {
                    Text(
                        agentOptions.reasoningEffort.displayName(
                            agentType: session.agentType
                        )
                    )
                        .font(.theme(.small))
                }
            }
            .foregroundStyle(reasoningEffortForegroundStyle)
            .padding(EdgeInsets(vertical: 6, horizontal: 8))
            .background(reasoningEffortBackgroundStyle, in: .capsule)
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(isSessionOptionsUpdateInFlight)
        .accessibilityLabel("Reasoning effort")
        .accessibilityValue(
            agentOptions.reasoningEffort.displayName(agentType: session.agentType)
        )
        .accessibilityHint("Cycles through available reasoning efforts")
    }

    private func reasoningEffortButtonTapped() {
        guard let nextEffort = session.nextReasoningEffort(
            after: agentOptions.reasoningEffort
        ) else {
            return
        }

        onReasoningEffortSelected(nextEffort)
    }

    private var reasoningEffortBackgroundStyle: AnyShapeStyle {
        if agentOptions.reasoningEffort == .ultra {
            AnyShapeStyle(LinearGradient.reasoningUltra)
        } else if agentOptions.reasoningEffort == .none {
            AnyShapeStyle(Color.clear)
        } else {
            AnyShapeStyle(Color.theme(.highlight))
        }
    }

    private var reasoningEffortForegroundStyle: Color {
        if agentOptions.reasoningEffort == .none {
            .theme(.textSecondary)
        } else if agentOptions.reasoningEffort == .ultra {
            .theme(.textPrimary)
        } else {
            .theme(.accent)
        }
    }

    private struct ReasoningEffortIcon: View {
        @ScaledMetric(relativeTo: .footnote) private var height = 16.0
        @ScaledMetric(relativeTo: .footnote) private var barWidth = 2.5
        @ScaledMetric(relativeTo: .footnote) private var spacing = 1.5

        let isSelected: Bool

        var body: some View {
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(1...6, id: \.self) { bar in
                    Capsule()
                        .fill(.theme(isSelected ? .accent : .textSecondary))
                        .frame(
                            width: barWidth,
                            height: height * CGFloat(bar) / 6
                        )
                }
            }
            .frame(height: height)
            .accessibilityHidden(true)
        }
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
            .sensoryFeedback(.selection, trigger: isInFlight) { _, isInFlight in
                isInFlight
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
            session: .preview(
                model: "gpt-5.6-sol",
                codexThinkingLevel: .extraHigh,
                fastMode: true
            ),
            agentOptions: .init(fastMode: true, reasoningEffort: .extraHigh),
            isSendInFlight: false,
            isSessionOptionsUpdateInFlight: false,
            isStopInFlight: false,
            isWorking: true,
            onFastModeTapped: { },
            onReasoningEffortSelected: { _ in },
            onSendTapped: { },
            onStopTapped: { }
        )
        .preferredColorScheme(.dark)
    }
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .preferredColorScheme(.dark)
}
