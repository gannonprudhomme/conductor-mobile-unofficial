import ConductorData
import LucideIcons
import SwiftUI

public struct AgentIcon: View {
    private let agentType: Session.AgentType
    private let size: CGFloat

    public init(agentType: Session.AgentType, size: CGFloat) {
        self.agentType = agentType
        self.size = size
    }

    public var body: some View {
        image
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(.theme(.textSecondary))
            .accessibilityLabel(Text(verbatim: agentType.displayName))
    }

    private var image: Image {
        switch agentType {
        case .codex:
            Image("OpenAI", bundle: .module)
        case .claude:
            Image("Claude", bundle: .module)
        default:
            Image(uiImage: Lucide.bot)
        }
    }
}

#Preview {
    HStack(spacing: 24) {
        AgentIcon(agentType: .codex, size: 24)

        AgentIcon(agentType: .claude, size: 24)

        AgentIcon(agentType: .init(rawValue: "unknown"), size: 24)
    }
    .padding()
    .background(.theme(.background))
    .preferredColorScheme(.dark)
}
