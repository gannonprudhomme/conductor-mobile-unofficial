//
//  LinearStatusIcon.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/10/26.
//

import SharedConductorData
import SwiftUI

public struct LinearStatusIcon: View {
    private let status: Workspace.Status
    private let size: CGFloat

    public init(status: Workspace.Status, size: CGFloat) {
        self.status = status
        self.size = size
    }

    public var body: some View {
        Image(imageResource)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
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
