import CoreText
import SwiftUI

public enum ThemeFontStyle {
    case body
    case small
    case extraSmall
    case inlineToolbarTitle
    case title

    public var size: CGFloat {
        switch self {
        case .extraSmall: 12
        case .small: 14
        case .body: 16
        case .inlineToolbarTitle: 16
        case .title: 28
        }
    }

    // TODO: Likely need to revisit these mappings
    // Not sure if context or size is what should be mapped
    public var textStyle: Font.TextStyle {
        switch self {
        case .extraSmall: .footnote
        case .body: .body
        case .small: .footnote
        case .inlineToolbarTitle: .body
        case .title: .title
        }
    }

    var fontName: String {
        "Geist-Regular"
    }
}

public extension Font {
    static func registerThemeFonts() {
        for fontFilename in ["Geist[wght].ttf", "GeistMono[wght].ttf"] {
            guard let url = Bundle.main.url(forResource: fontFilename, withExtension: nil) else {
                assertionFailure("Missing bundled font: \(fontFilename)")
                continue
            }

            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func theme(_ style: ThemeFontStyle) -> Font {
        .custom(
            style.fontName,
            size: style.size,
            relativeTo: style.textStyle
        )
    }
}
