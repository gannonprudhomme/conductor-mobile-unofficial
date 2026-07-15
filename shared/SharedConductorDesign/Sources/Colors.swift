//
//  Colors.swift
//  SharedConductorDesign
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SwiftUI

public enum ThemeColorStyle {
    /// Matches Conductor's `--link-foreground` and `--border-highlight` CSS variables.
    case accent
    case background
    case border
    case controlHover
    case destructive
    case destructiveBackground
    case destructiveBorder
    case foreground
    case gitGreen
    case gitRed
    case gray500
    case highlight
    case highlightForeground
    case input
    case muted
    case sidebarMutedForeground
    case statusDone
    case statusInProgress
    case statusInReview
    case success
    case successBackground
    case successBorder
    case textPrimary
    case textSecondary
    case unread
}

public extension ShapeStyle where Self == Color {
    static func theme(_ style: ThemeColorStyle) -> Self {
        switch style {
        case .accent:
            Color(red: 204.0 / 255.0, green: 166.0 / 255.0, blue: 148.0 / 255.0)

        case .background:
            Color(red: 20.0 / 255.0, green: 17.0 / 255.0, blue: 16.0 / 255.0)

        case .border:
            Color.white.opacity(0.1)

        case .controlHover:
            Color(red: 44.0 / 255.0, green: 40.0 / 255.0, blue: 38.0 / 255.0)

        case .destructive, .gitRed:
            Color(red: 248.0 / 255.0, green: 114.0 / 255.0, blue: 114.0 / 255.0)

        case .destructiveBackground:
            Color(red: 43.0 / 255.0, green: 26.0 / 255.0, blue: 25.0 / 255.0)

        case .destructiveBorder:
            Color(red: 125.0 / 255.0, green: 61.0 / 255.0, blue: 61.0 / 255.0)

        case .gray500:
            // Matches Conductor's `--color-gray-500` CSS variable.
            Color(red: 142.0 / 255.0, green: 136.0 / 255.0, blue: 133.0 / 255.0)

        case .foreground, .textPrimary:
            Color(red: 234.0 / 255.0, green: 232.0 / 255.0, blue: 230.0 / 255.0)

        case .gitGreen, .success:
            Color(red: 74.0 / 255.0, green: 222.0 / 255.0, blue: 128.0 / 255.0)

        case .successBackground:
            Color(red: 25.0 / 255.0, green: 37.0 / 255.0, blue: 27.0 / 255.0)

        case .successBorder:
            Color(red: 45.0 / 255.0, green: 111.0 / 255.0, blue: 68.0 / 255.0)

        case .highlight:
            Color(red: 42.0 / 255.0, green: 30.0 / 255.0, blue: 29.0 / 255.0)

        case .highlightForeground:
            Color(red: 243.0 / 255.0, green: 236.0 / 255.0, blue: 231.0 / 255.0)

        case .input:
            Color(red: 1, green: 1, blue: 1, opacity: 0.2)

        case .muted:
            Color(red: 33.0 / 255.0, green: 30.0 / 255.0, blue: 28.0 / 255.0)

        case .sidebarMutedForeground:
            Color.white.opacity(0.6)

        case .statusDone, .unread:
            Color(red: 211.0 / 255.0, green: 177.0 / 255.0, blue: 160.0 / 255.0)

        case .statusInProgress:
            Color(red: 255.0 / 255.0, green: 213.0 / 255.0, blue: 0.0 / 255.0)

        case .statusInReview:
            Color(red: 44.0 / 255.0, green: 224.0 / 255.0, blue: 127.0 / 255.0)

        case .textSecondary:
            Color(red: 165.0 / 255.0, green: 160.0 / 255.0, blue: 156.0 / 255.0)
        }
    }
}
