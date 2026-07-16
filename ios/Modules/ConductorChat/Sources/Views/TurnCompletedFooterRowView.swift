//
//  TurnCompletedFooterRowView.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/13/26.
//

import ConductorDesign
import LucideIcons
import SwiftUI

struct TurnCompletedFooterRowView: View {
    let footer: DisplayedChatRow.TurnFooter
    @State private var copyCount = 0
    @State private var isShowingCopiedConfirmation = false

    private let animation: Animation = .interactiveSpring(extraBounce: 0.3)
    private let transition = AnyTransition.asymmetric(insertion: .scale, removal: .opacity)

    var body: some View {
        HStack(spacing: 12) {
            Text(TurnInProgressView.elapsedTimeDescription(footer.elapsedTime, showsTenths: false))

            Button {
                UIPasteboard.general.string = footer.copyableText
                copyCount += 1
                withAnimation(animation) {
                    isShowingCopiedConfirmation = true
                }
            } label: {
                Label {
                    Text("Copy final message")
                } icon: {
                    if isShowingCopiedConfirmation {
                        LucideIcon(Lucide.check, style: .small)
                            .transition(transition)
                    } else {
                        LucideIcon(Lucide.copy, style: .small)
                            .transition(transition)
                    }
                }
                .labelStyle(.iconOnly)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.selection, trigger: copyCount)
            .task(id: copyCount) { // start the animation
                guard copyCount > 0 else {
                    return
                }

                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else {
                    return
                }

                withAnimation(animation) {
                    isShowingCopiedConfirmation = false
                }
            }
        }
        .font(.theme(.codeSmall))
        .foregroundStyle(.theme(.textSecondary))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    TurnCompletedFooterRowView(
        footer: .init(
            id: "turn-1",
            elapsedTime: 2_112,
            copyableText: "The complete final message."
        )
    )
    .padding()
    .background(.theme(.background))
    .preferredColorScheme(.dark)
}
