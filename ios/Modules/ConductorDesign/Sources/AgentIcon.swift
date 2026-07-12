//
//  AgentIcon.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import ConductorMobileData
import LucideIcons
import SwiftUI

public struct AgentIcon: View {
    private let agentType: Session.AgentType
    private let size: CGFloat
    private let textStyle: Font.TextStyle

    public init(
        agentType: Session.AgentType,
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle
    ) {
        self.agentType = agentType
        self.size = size
        self.textStyle = textStyle
    }

    public var body: some View {
        LucideIcon(image, size: size, relativeTo: textStyle)
            .foregroundStyle(.theme(.textSecondary))
            .accessibilityLabel(Text(verbatim: agentType.displayName))
    }

    private var image: UIImage {
        switch agentType {
        case .codex:
            UIImage(resource: .openAI)
        case .claude:
            UIImage(resource: .claude)
        default:
            Lucide.bot
        }
    }
}

#Preview {
    HStack(spacing: 24) {
        AgentIcon(agentType: .codex, size: 24, relativeTo: .body)

        AgentIcon(agentType: .claude, size: 24, relativeTo: .body)

        AgentIcon(agentType: .init(rawValue: "unknown"), size: 24, relativeTo: .body)
    }
    .padding()
    .background(.theme(.background))
    .preferredColorScheme(.dark)
}
