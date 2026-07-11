import ConductorData
import LucideIcons
import SwiftUI

public struct RepositoryIcon: View {
    @ScaledMetric private var scaledSize: CGFloat

    private let iconName: String?
    private let avatarURL: URL?
    private let size: CGFloat
    private let textStyle: Font.TextStyle

    public init(
        iconName: String?,
        avatarURL: URL?,
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle
    ) {
        self.iconName = iconName
        self.avatarURL = avatarURL
        self.size = size
        self.textStyle = textStyle
        self._scaledSize = ScaledMetric(
            wrappedValue: size,
            relativeTo: textStyle
        )
    }

    public init(
        repository: Repository,
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle
    ) {
        self.init(
            iconName: repository.icon,
            avatarURL: repository.githubOwnerAvatarURL,
            size: size,
            relativeTo: textStyle
        )
    }

    public init(
        repository: Repository?,
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle
    ) {
        self.init(
            iconName: repository?.icon,
            avatarURL: repository?.githubOwnerAvatarURL,
            size: size,
            relativeTo: textStyle
        )
    }

    public var body: some View {
        Group {
            if let iconName, !iconName.isEmpty, let icon = UIImage(lucideId: iconName) {
                LucideIcon(icon, size: size, relativeTo: textStyle)
                    .foregroundStyle(.theme(.textSecondary))
            } else if iconName == nil, let avatarURL {
                CachedAsyncImage(url: avatarURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                            .clipShape(.rect(cornerRadius: scaledSize / 5))
                    } else {
                        fallbackIcon
                    }
                }
            } else {
                fallbackIcon
            }
        }
        .frame(width: scaledSize, height: scaledSize)
        .accessibilityHidden(true)
    }

    private var fallbackIcon: some View {
        LucideIcon(Lucide.folderGit2, size: size, relativeTo: textStyle)
            .foregroundStyle(.theme(.textSecondary))
    }
}
