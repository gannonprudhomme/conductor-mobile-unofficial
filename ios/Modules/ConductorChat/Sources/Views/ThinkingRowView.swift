//
//  ThinkingRowView.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/28/26.
//

import ConductorDesign
import LucideIcons
import SwiftUI

struct ThinkingRowView: View {
    let content: String

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text("Thinking")
            } icon: {
                LucideIcon(Lucide.brain, style: .small)
            }
            .labelStyle(.conductorSmall)
            .font(.theme(.small))
            .foregroundStyle(.theme(.textPrimary))
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)

            Text(content)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.theme(.extraSmall))
                .foregroundStyle(.theme(.textSecondary))
                .padding(EdgeInsets(vertical: 4, horizontal: 6))
                .background(
                    Color.theme(.muted),
                    in: .rect(cornerRadius: 6)
                )
        }
    }
}

#Preview {
    ThinkingRowView(
        content: "I need to rewrite the plan file without hard-wrapped lines and then propose it again."
    )
    .padding()
    .background(.theme(.background))
    .preferredColorScheme(.dark)
}
