//
//  UnreadIcon.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/11/26.
//

import SwiftUI

public struct UnreadIcon: View {
    private let size: CGFloat

    public init(size: CGFloat) {
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(.theme(.unread))
            .frame(width: size, height: size)
            .accessibilityLabel("Unread")
    }
}
