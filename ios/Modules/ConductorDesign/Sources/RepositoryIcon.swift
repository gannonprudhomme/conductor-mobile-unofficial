//
//  RepositoryIcon.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import ConductorMobileData
import LucideIcons
import SwiftUI

public struct RepositoryIcon: View {
    @ScaledMetric private var scaledSize: CGFloat

    private let iconName: String?
    private let faviconURL: URL?
    private let avatarURL: URL?
    private let size: CGFloat
    private let textStyle: Font.TextStyle

    public init(
        iconName: String?,
        faviconURL: URL?,
        avatarURL: URL?,
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle
    ) {
        self.iconName = iconName
        self.faviconURL = faviconURL
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
            faviconURL: DesktopClient.repositoryIconURL(for: repository),
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
            faviconURL: repository.map { DesktopClient.repositoryIconURL(for: $0) },
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
            } else if let faviconURL {
                faviconImage(url: faviconURL)
            } else if let avatarURL {
                remoteImage(url: avatarURL)
            } else {
                fallbackIcon
            }
        }
        .frame(width: scaledSize, height: scaledSize)
        .accessibilityHidden(true)
    }

    private func faviconImage(url: URL) -> some View {
        CachedAsyncImage(url: url, revalidatesCachedResponse: true) { phase in
            if let image = phase.image {
                styled(image: image)
            } else if phase.error != nil, let avatarURL {
                remoteImage(url: avatarURL)
            } else {
                fallbackIcon
            }
        }
    }

    private func remoteImage(url: URL) -> some View {
        CachedAsyncImage(url: url) { image in
            styled(image: image)
        } placeholder: {
            fallbackIcon
        }
    }

    private func styled(image: Image) -> some View {
        image
            .resizable()
            .scaledToFill()
            .clipShape(.rect(cornerRadius: scaledSize / 5))
    }

    private var fallbackIcon: some View {
        LucideIcon(Lucide.folderGit2, size: size, relativeTo: textStyle)
            .foregroundStyle(.theme(.textSecondary))
    }
}
