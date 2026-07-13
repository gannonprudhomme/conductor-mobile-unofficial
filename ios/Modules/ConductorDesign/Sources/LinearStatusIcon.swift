//
//  LinearStatusIcon.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/10/26.
//

import SharedConductorData
import SwiftUI

public struct LinearStatusIcon: View {
    /// Bakes the status tint into the image for UIKit-backed surfaces, such as
    /// context menus, that replace SwiftUI foreground styles with their own tint.
    private let preservesColor: Bool
    private let status: Workspace.Status
    private let size: CGFloat

    public init(
        status: Workspace.Status,
        size: CGFloat,
        preservesColor: Bool = false
    ) {
        self.preservesColor = preservesColor
        self.status = status
        self.size = size
    }

    public var body: some View {
        image
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var image: Image {
        if preservesColor {
            Image(
                uiImage: UIImage(resource: imageResource)
                    .withTintColor(UIColor(color), renderingMode: .alwaysOriginal)
            )
        } else {
            Image(imageResource)
                .renderingMode(.template)
        }
    }

    private var imageResource: ImageResource {
        switch status {
        case .done: .linearStatusDone
        case .inReview: .linearStatusInReview
        case .inProgress: .linearStatusInProgress
        case .backlog: .linearStatusBacklog
        case .canceled: .linearStatusCanceled
        default: .linearStatusDefault
        }
    }

    private var color: Color {
        switch status {
        case .done: .theme(.statusDone)
        case .inReview: .theme(.statusInReview)
        case .inProgress: .theme(.statusInProgress)
        default: .theme(.textSecondary)
        }
    }
}
