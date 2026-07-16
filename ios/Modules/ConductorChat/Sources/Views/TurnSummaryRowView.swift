//
//  TurnSummaryRowView.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/13/26.
//

import ConductorDesign
import LucideIcons
import SwiftUI

struct TurnSummaryRowView: View {
    @Environment(\.accessibilityReduceMotion) private var isReduceMotionEnabled

    let summary: DisplayedChatRow.TurnSummary
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
                    .lineLimit(1)
                    .font(.theme(.small))
                    .layoutPriority(1)

                ForEach(summary.toolIcons) { icon in
                    LucideIcon(icon.image, style: .small)
                }
            } icon: {
                LucideIcon(Lucide.chevronDown, style: .small)
                    .rotationEffect(.degrees(summary.isExpanded ? 0 : -90))
            }
            .labelStyle(.conductorSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Preserve an approximately 44-point tap target without adding layout height.
            .contentShape(
                .interaction,
                Rectangle().inset(by: -ChatRowLayout.summaryHitTargetExpansion)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.theme(.textSecondary))
        .sensoryFeedback(.selection, trigger: summary.isExpanded)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(summary.isExpanded ? "Expanded" : "Collapsed")
        .animation(
            isReduceMotionEnabled ? nil : .default,
            value: summary.isExpanded
        )
    }

    private var title: String {
        let toolCalls = "\(summary.toolCallCount) tool call\(summary.toolCallCount == 1 ? "" : "s")"
        let messages = "\(summary.messageCount) message\(summary.messageCount == 1 ? "" : "s")"
        return "\(toolCalls), \(messages)"
    }

    private var accessibilityLabel: String {
        guard !summary.toolIcons.isEmpty else {
            return title
        }

        let categories = summary.toolIcons
            .map(\.accessibilityLabel)
            .joined(separator: ", ")
        return "\(title). Tools: \(categories)"
    }
}

#Preview {
    VStack(spacing: 8) {
        TurnSummaryRowView(
            summary: .init(
                id: "collapsed",
                isExpanded: false,
                toolCallCount: 34,
                messageCount: 12,
                toolIcons: [.fileText, .filePen, .terminal, .search]
            ),
            action: {}
        )

        TurnSummaryRowView(
            summary: .init(
                id: "expanded",
                isExpanded: true,
                toolCallCount: 1,
                messageCount: 1,
                toolIcons: [.globe]
            ),
            action: {}
        )
    }
    .padding()
    .background(.theme(.background))
    .preferredColorScheme(.dark)
}
