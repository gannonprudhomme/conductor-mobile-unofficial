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
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric private var scaledSize: CGFloat

    private let iconName: String?
    private let faviconURL: URL?
    private let avatarURL: URL?

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
            faviconURL: repository.flatMap { DesktopClient.repositoryIconURL(for: $0) },
            avatarURL: repository?.githubOwnerAvatarURL,
            size: size,
            relativeTo: textStyle
        )
    }

    public var body: some View {
        Group {
            if let iconName, !iconName.isEmpty, let icon = UIImage(lucideId: iconName) {
                Image(uiImage: templateImage(icon))
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
        CachedAsyncImage(
            url: url,
            revalidatesCachedResponse: true,
            retryDelays: [.seconds(1), .seconds(2), .seconds(4)],
            prepareImage: prepareRemoteImage
        ) { phase in
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
        CachedAsyncImage(url: url, prepareImage: prepareRemoteImage) { phase in
            if let image = phase.image {
                styled(image: image)
            } else {
                fallbackIcon
            }
        }
    }

    private func styled(image: Image) -> some View {
        image
            .resizable()
            .scaledToFill()
            .clipShape(.rect(cornerRadius: scaledSize / 5))
    }

    private func prepareRemoteImage(_ image: UIImage) async -> UIImage? {
        await Self.prepareRemoteImage(
            image,
            size: scaledSize,
            displayScale: displayScale
        )
    }

    static func prepareRemoteImage(
        _ image: UIImage,
        size: CGFloat,
        displayScale: CGFloat
    ) async -> UIImage? {
        // Thumbnailing preserves the source scale, so normalize it before restoring display scale.
        let thumbnailSize = CGSize(
            width: size * displayScale / image.scale,
            height: size * displayScale / image.scale
        )
        guard let thumbnail = await image.byPreparingThumbnail(ofSize: thumbnailSize),
            let cgImage = thumbnail.cgImage
        else {
            return nil
        }
        let normalizedImage = UIImage(
            cgImage: cgImage,
            scale: displayScale,
            orientation: thumbnail.imageOrientation
        )
        let bounds = CGRect(origin: .zero, size: normalizedImage.size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = displayScale
        // UIKit-backed menus discard SwiftUI clip shapes, so bake the shared radius into pixels.
        return UIGraphicsImageRenderer(
            size: bounds.size,
            format: format
        ).image { _ in
            UIBezierPath(
                roundedRect: bounds,
                cornerRadius: size / 5
            ).addClip()
            normalizedImage.draw(in: bounds)
        }
    }

    private var fallbackIcon: some View {
        Image(uiImage: templateImage(Lucide.folderGit2))
    }

    private func templateImage(_ image: UIImage) -> UIImage {
        let bounds = CGRect(
            origin: .zero,
            size: CGSize(width: scaledSize, height: scaledSize)
        )
        return UIGraphicsImageRenderer(size: bounds.size).image { _ in
            image.draw(in: bounds)
        }
        .withRenderingMode(.alwaysTemplate)
    }
}
