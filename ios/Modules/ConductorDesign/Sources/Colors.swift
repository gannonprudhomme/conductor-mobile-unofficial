import SwiftUI

public enum ThemeColorStyle {
    case background
    case destructive
    case foreground
    case gitGreen
    case gitRed
    case highlight
    case highlightForeground
    case input
    case muted
    case textPrimary
    case textSecondary
}

public extension ShapeStyle where Self == Color {
    static func theme(_ style: ThemeColorStyle) -> Self {
        switch style {
        case .background:
            Color(red: 20.0 / 255.0, green: 17.0 / 255.0, blue: 16.0 / 255.0)

        case .destructive, .gitRed:
            Color(red: 248.0 / 255.0, green: 114.0 / 255.0, blue: 114.0 / 255.0)

        case .foreground, .textPrimary:
            Color(red: 234.0 / 255.0, green: 232.0 / 255.0, blue: 230.0 / 255.0)

        case .gitGreen:
            Color(red: 74.0 / 255.0, green: 222.0 / 255.0, blue: 128.0 / 255.0)

        case .highlight:
            Color(red: 42.0 / 255.0, green: 30.0 / 255.0, blue: 29.0 / 255.0)

        case .highlightForeground:
            Color(red: 243.0 / 255.0, green: 236.0 / 255.0, blue: 231.0 / 255.0)

        case .input:
            Color(red: 1, green: 1, blue: 1, opacity: 0.2)

        case .muted:
            Color(red: 33.0 / 255.0, green: 30.0 / 255.0, blue: 28.0 / 255.0)

        case .textSecondary:
            Color(red: 165.0 / 255.0, green: 160.0 / 255.0, blue: 156.0 / 255.0)
        }
    }
}
