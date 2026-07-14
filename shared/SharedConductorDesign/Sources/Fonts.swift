//
//  Fonts.swift
//  SharedConductorDesign
//
//  Created by Gannon Prudomme on 7/12/26.
//

import CoreText
import SwiftUI

public enum ThemeFontStyle {
    case body
    case small
    case extraSmall
    case extraExtraSmall
    /// Monospaced counterpart to ``body``.
    case codeBody
    /// Monospaced counterpart to ``small``.
    case codeSmall
    /// Monospaced counterpart to ``extraSmall``.
    case codeExtraSmall
    case inlineToolbarTitle
    case heading
    case title

    public var size: CGFloat {
        switch self {
        case .extraExtraSmall: 11
        case .extraSmall, .codeExtraSmall: 12
        case .small, .codeSmall: 14
        case .body, .codeBody: 16
        case .inlineToolbarTitle: 16
        case .heading: 24
        case .title: 28
        }
    }

    // TODO: Likely need to revisit these mappings
    // Not sure if context or size is what should be mapped
    public var textStyle: Font.TextStyle {
        switch self {
        case .extraExtraSmall: .caption2
        case .extraSmall, .codeExtraSmall: .footnote
        case .body, .codeBody: .body
        case .small, .codeSmall: .footnote
        case .inlineToolbarTitle: .body
        case .heading, .title: .title
        }
    }

    public var fontName: String {
        switch self {
        case .codeBody, .codeSmall, .codeExtraSmall: "GeistMono-Regular"
        default: "Geist-Regular"
        }
    }
}

public extension Font {
    // Swift initializes static lets lazily and serializes concurrent access, so registration
    // runs only once when the first theme font is requested.
    private static let themeFontsRegistration: Void = {
        for fontFilename in ["Geist[wght].ttf", "GeistMono[wght].ttf"] {
            guard let url = Bundle.module.url(forResource: fontFilename, withExtension: nil) else {
                assertionFailure("Missing bundled font: \(fontFilename)")
                continue
            }

            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    static func theme(_ style: ThemeFontStyle) -> Font {
        // Reading the static triggers registration before SwiftUI resolves the custom font.
        _ = themeFontsRegistration

        return .custom(
            style.fontName,
            size: style.size,
            relativeTo: style.textStyle
        )
    }
}
