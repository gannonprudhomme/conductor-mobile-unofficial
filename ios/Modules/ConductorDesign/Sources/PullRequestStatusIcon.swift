//
//  PullRequestStatusIcon.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/18/26.
//

import ConductorMobileData
import LucideIcons
import SwiftUI

public struct PullRequestStatusIcon: View {
    private let status: MobileWorkspaceState.PullRequestStatus
    private let size: CGFloat
    private let textStyle: Font.TextStyle

    public init(
        status: MobileWorkspaceState.PullRequestStatus,
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle
    ) {
        self.status = status
        self.size = size
        self.textStyle = textStyle
    }

    public var body: some View {
        LucideIcon(presentation.image, size: size, relativeTo: textStyle)
            .foregroundStyle(.theme(presentation.color))
    }

    private var presentation: (image: UIImage, color: ThemeColorStyle) {
        switch status {
        case .draft:
            (Lucide.gitPullRequestDraft, .textSecondary)
        case .failingChecks:
            (Lucide.x, .gitRed)
        case .readyToMerge:
            (Lucide.gitPullRequest, .gitGreen)
        case .mergeConflict:
            (Lucide.gitPullRequestClosed, .pullRequestConflict)
        case .merged:
            (Lucide.gitMerge, .pullRequestMerged)
        }
    }
}
