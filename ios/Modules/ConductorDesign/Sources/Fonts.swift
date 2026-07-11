import CoreText
import SwiftUI

public enum ThemeFontStyle {
    case body
    case small
    case extraSmall
    case extraExtraSmall
    case inlineToolbarTitle
    case title

    public var size: CGFloat {
        switch self {
        case .extraExtraSmall: 11
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
        case .extraExtraSmall: .caption2
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
    // Swift initializes static lets lazily and serializes concurrent access, so registration
    // runs only once when the first theme font is requested.
    private static let themeFontsRegistration: Void = {
        for fontFilename in ["Geist[wght].ttf", "GeistMono[wght].ttf"] {
            guard let url = Bundle.main.url(forResource: fontFilename, withExtension: nil) else {
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
