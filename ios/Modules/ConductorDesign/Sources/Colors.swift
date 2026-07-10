import SwiftUI

public enum ThemeColorStyle {
    case background
    case foreground
    case textPrimary
    case textSecondary
}

public extension ShapeStyle where Self == Color {
    static func theme(_ style: ThemeColorStyle) -> Self {
        switch style {
        case .background:
            Color(red: 20.0 / 255.0, green: 17.0 / 255.0, blue: 16.0 / 255.0)

        case .foreground, .textPrimary:
            Color(red: 234.0 / 255.0, green: 232.0 / 255.0, blue: 230.0 / 255.0)

        case .textSecondary:
            Color(red: 165.0 / 255.0, green: 160.0 / 255.0, blue: 156.0 / 255.0)
        }
    }
}
