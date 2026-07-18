//
//  AssistantMessageTextView.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/11/26.
//

import ConductorDesign
import MarkdownUI
import SwiftUI

/// Renders one Markdown chunk parsed and retained by its stable chat row.
struct AssistantMessageTextView: View {
    @ScaledMetric(relativeTo: ThemeFontStyle.body.textStyle)
    private var markdownRootFontSize = ThemeFontStyle.body.size

    let chunk: Turn.Row.AssistantMessage.TextContent.Chunk
    /// Used to determine if we should render it the normal foreground color or muted (secondary color)
    let isMostRecentTextInTurn: Bool

    var body: some View {
        Markdown(chunk.markdown)
            // MarkdownUI's default providers automatically download every remote image when this row appears.
            // Assistant Markdown can contain URLs copied from tools or the web, so that behavior could disclose when the user opened a chat and add network work while scrolling.
            // Until remote images are routed through CachedAsyncImage, render bundled assets only and never make an implicit third-party request.
            .markdownImageProvider(.asset)
            .markdownInlineImageProvider(.asset)
            .markdownTheme(
                .assistantMessage(
                    foregroundColor: .theme(
                        isMostRecentTextInTurn ? .textPrimary : .textSecondary
                    )
                )
            )
            // The MarkdownUI theme below refers to Geist by PostScript name and therefore does not call Font.theme.
            // Applying the body font triggers ConductorDesign's one-time registration before MarkdownUI tries to resolve the same bundled font names.
            // (Gannon: this is likely overly defensive but doesn't hurt to have. Probably added this while it was optimizing the rendering autonomously)
            .font(.theme(.body))
            .textSelection(.enabled)
            // Each chunk is a separate hosted row, so MarkdownUI cannot preserve the original margin between blocks on opposite sides of a chunk boundary.
            // Restore only the portion not already supplied by the chat layout's normal inter-row spacing.
            .padding(
                .top,
                chunk.spacingBefore.additionalTopPadding(
                    rootFontSize: markdownRootFontSize,
                    existingSpacing: ChatRowLayout.interRowSpacing
                )
            )
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension Theme {
    @MainActor
    static func assistantMessage(foregroundColor: Color) -> Theme {
        // MarkdownUI expresses nested font sizes relative to the 16-point body font.
        // 14 / 16 = 0.875 em, keeping code aligned with ThemeFontStyle.codeSmall.
        let codeFontScale = ThemeFontStyle.codeSmall.size / ThemeFontStyle.body.size

        return Theme.basic
            .text {
                FontFamily(.custom(ThemeFontStyle.body.fontName))
                FontSize(ThemeFontStyle.body.size)
                ForegroundColor(foregroundColor)
            }
            .code {
                FontFamily(.custom(ThemeFontStyle.codeSmall.fontName))
                FontSize(.em(codeFontScale))
            }
            .link {
                ForegroundColor(.theme(.statusDone)) // TODO: Need to use a better color name
            }
            .paragraph { configuration in
                configuration.label
                    // Preserve Theme.basic's 2.4-point leading at the base body-font size.
                    .relativeLineSpacing(.em(2.4 / ThemeFontStyle.body.size))
                    .markdownMargin(top: .zero, bottom: .em(1))
            }
            .codeBlock { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: true, vertical: true)
                        // Preserve the previous Textual renderer's 5.46-point additional
                        // spacing at the base code-font size.
                        .relativeLineSpacing(.em(5.46 / ThemeFontStyle.codeSmall.size))
                        .padding(EdgeInsets(vertical: 8, horizontal: 14))
                        .markdownTextStyle {
                            FontFamily(.custom(ThemeFontStyle.codeSmall.fontName))
                            FontSize(.em(codeFontScale))
                        }
                }
                // TODO: Corner radius
                .background(.theme(.muted), in: .rect(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(.theme(.input), lineWidth: 1)
                }
                // One 14-point code-font unit at a 16-point root is 14 / 16 em.
                .markdownMargin(top: .em(codeFontScale), bottom: .em(1))
            }
            .table { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        // TODO: I don't like using input for this
                        .markdownTableBorderStyle(.init(color: .theme(.input)))
                        .fixedSize(horizontal: true, vertical: true)
                }
                .markdownMargin(top: .zero, bottom: .em(1))
            }
            .thematicBreak {
                Divider()
                    // TODO: I don't like using input for this
                    .overlay(.theme(.input))
                    // Preserve Theme.basic's two-em margins on both sides of a rule.
                    .markdownMargin(top: .em(2), bottom: .em(2))
            }
    }
}

#Preview {
    let chunk = Turn.Row.AssistantMessage.TextContent.Chunk(
        id: 0,
        source: """
        # Markdown preview

        This preview covers **emphasis**, [links](https://conductor.build), and `inline code`.

        > Assistant messages can include block quotes.

        - Lists remain aligned.
        - Their spacing matches the surrounding text.

        ```swift
        let greeting = "Hello, world!"
        ```

        | Renderer | Result |
        | --- | --- |
        | MarkdownUI | Enabled |

        ---
        """,
        spacingBefore: .none
    )

    ScrollView {
        AssistantMessageTextView(
            chunk: chunk,
            isMostRecentTextInTurn: true
        )
            .padding()
    }
    .background(.theme(.background))
    .preferredColorScheme(.dark)
}
