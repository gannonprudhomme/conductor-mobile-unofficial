import CoreText
import SwiftUI

public enum ThemeFontStyle {
    case body
    case footnote
    case inlineToolbarTitle
    case title

    var size: CGFloat {
        switch self {
        case .body:
            16
        case .footnote:
            13
        case .inlineToolbarTitle:
            16
        case .title:
            28
        }
    }

    var textStyle: Font.TextStyle {
        switch self {
        case .body:
            .body
        case .footnote:
            .footnote
        case .inlineToolbarTitle:
            .body
        case .title:
            .title
        }
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
            "Geist-Regular",
            size: style.size,
            relativeTo: style.textStyle
        )
    }
}
