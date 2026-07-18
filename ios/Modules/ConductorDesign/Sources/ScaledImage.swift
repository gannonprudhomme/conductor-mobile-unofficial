//
//  ScaledImage.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/16/26.
//

import SwiftUI

public struct ScaledImage: View {
    @ScaledMetric private var size: CGFloat

    private let image: UIImage

    public init(
        _ resource: ImageResource,
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle
    ) {
        self.image = UIImage(resource: resource)
        self._size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
    }

    public static func gitHub(
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle
    ) -> Self {
        Self(.gitHub, size: size, relativeTo: textStyle)
    }

    public var body: some View {
        Image(uiImage: scaledImage)
            .accessibilityHidden(true)
    }

    private var scaledImage: UIImage {
        let size = CGSize(width: size, height: size)
        let bounds = CGRect(origin: .zero, size: size)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: bounds)
        }
        .withRenderingMode(.alwaysTemplate)
    }
}
