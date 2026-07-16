//
//  GitHubIcon.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/16/26.
//

import SwiftUI

public struct GitHubIcon: View {
    @ScaledMetric private var size: CGFloat

    public init(size: CGFloat, relativeTo textStyle: Font.TextStyle) {
        self._size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
    }

    public var body: some View {
        Image(.gitHub)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
