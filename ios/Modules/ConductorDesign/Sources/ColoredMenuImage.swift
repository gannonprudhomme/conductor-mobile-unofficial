//
//  ColoredMenuImage.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/13/26.
//

import LucideIcons
import SwiftUI

/// Creates an `Image`
public struct ColoredMenuImage: View {
    private let color: Color
    private let image: UIImage

    public init(
        _ image: UIImage,
        color: Color = .theme(.textSecondary)
    ) {
        self.color = color
        self.image = image
    }

    public var body: some View {
        // UIKit-backed menus ignore SwiftUI foreground styles, so bake in the tint.
        Image(
            uiImage: image.withTintColor(
                UIColor(color),
                renderingMode: .alwaysOriginal
            )
        )
        .accessibilityHidden(true)
    }
}

#Preview("Menu icon color comparison") {
    VStack(spacing: 16) {
        Text("Both icons request the unread color")
            .font(.theme(.small))
            .foregroundStyle(.theme(.textSecondary))

        Menu {
            Button(action: {}) {
                Label {
                    Text("LucideIcon (no color!)")
                } icon: {
                    LucideIcon(Lucide.mail, style: .body)
                        .foregroundStyle(.theme(.unread))
                }
            }

            Button(action: {}) {
                Label {
                    Text("SFSymbol (won't change)")
                } icon: {
                    Image(systemName: "trash")
                        .foregroundStyle(.theme(.unread))
                }
            }

            Button(action: {}) {
                Label {
                    Text("ColoredMenuImage - works")
                } icon: {
                    ColoredMenuImage(Lucide.mail, color: .theme(.unread))
                }
            }
        } label: {
            Text("Compare menu icons")
                .font(.theme(.body))
                .foregroundStyle(.theme(.textPrimary))
        }
    }
    .padding()
    .background(.theme(.background))
    .preferredColorScheme(.dark)
}
