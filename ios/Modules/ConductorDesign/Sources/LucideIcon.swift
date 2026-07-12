//
//  LucideIcon.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/11/26.
//

import SwiftUI

public struct LucideIcon: View {
    @ScaledMetric private var size: CGFloat

    private let image: UIImage

    public init(
        _ image: UIImage,
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle
    ) {
        self.image = image
        self._size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
    }

    public init(_ image: UIImage, style: ThemeFontStyle) {
        self.init(
            image,
            size: style.size,
            relativeTo: style.textStyle
        )
    }

    public var body: some View {
        Image(uiImage: image)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
