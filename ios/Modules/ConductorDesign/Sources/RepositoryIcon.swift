import ConductorData
import LucideIcons
import SwiftUI

public struct RepositoryIcon: View {
    private let iconName: String?
    private let avatarURL: URL?
    private let size: CGFloat

    public init(iconName: String?, avatarURL: URL?, size: CGFloat) {
        self.iconName = iconName
        self.avatarURL = avatarURL
        self.size = size
    }

    public init(repository: Repository, size: CGFloat) {
        self.init(
            iconName: repository.icon,
            avatarURL: repository.githubOwnerAvatarURL,
            size: size
        )
    }

    public init(repository: Repository?, size: CGFloat) {
        self.init(
            iconName: repository?.icon,
            avatarURL: repository?.githubOwnerAvatarURL,
            size: size
        )
    }

    public var body: some View {
        Group {
            if let iconName, !iconName.isEmpty, let icon = UIImage(lucideId: iconName) {
                Image(uiImage: icon)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.theme(.textSecondary))
            } else if iconName == nil, let avatarURL {
                CachedAsyncImage(url: avatarURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                            .clipShape(.rect(cornerRadius: size / 5))
                    } else {
                        fallbackIcon
                    }
                }
            } else {
                fallbackIcon
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var fallbackIcon: some View {
        Image(uiImage: Lucide.folderGit2)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.theme(.textSecondary))
    }
}
