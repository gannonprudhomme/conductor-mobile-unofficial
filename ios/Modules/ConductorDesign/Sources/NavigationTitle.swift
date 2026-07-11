import SwiftUI

public extension View {
    func themedNavigationTitle(
        _ screen: LocalizedStringKey,
        subtitle: String? = nil,
        alignment: HorizontalAlignment = .center
    ) -> some View {
        themedNavigationTitle(Text(screen), alignment: alignment) {
            if let subtitle {
                Text(verbatim: subtitle)
            }
        }
    }

    func themedNavigationTitle<Subtitle: View>(
        _ screen: LocalizedStringKey,
        alignment: HorizontalAlignment = .center,
        @ViewBuilder subtitle: () -> Subtitle
    ) -> some View {
        themedNavigationTitle(
            Text(screen),
            alignment: alignment,
            subtitle: subtitle
        )
    }

    func themedNavigationTitle(
        verbatim screen: String,
        subtitle: String? = nil,
        alignment: HorizontalAlignment = .center
    ) -> some View {
        themedNavigationTitle(Text(verbatim: screen), alignment: alignment) {
            if let subtitle {
                Text(verbatim: subtitle)
            }
        }
    }

    func themedNavigationTitle<Subtitle: View>(
        verbatim screen: String,
        alignment: HorizontalAlignment = .center,
        @ViewBuilder subtitle: () -> Subtitle
    ) -> some View {
        themedNavigationTitle(
            Text(verbatim: screen),
            alignment: alignment,
            subtitle: subtitle
        )
    }

    private func themedNavigationTitle<Subtitle: View>(
        _ screen: Text,
        alignment: HorizontalAlignment,
        @ViewBuilder subtitle: () -> Subtitle
    ) -> some View {
        navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ThemedNavigationTitleContent(
                        screen: screen,
                        subtitle: subtitle(),
                        alignment: alignment
                    )
                }
            }
    }
}

private struct ThemedNavigationTitleContent<Subtitle: View>: View {
    let screen: Text
    let subtitle: Subtitle
    let alignment: HorizontalAlignment

    var body: some View {
        if alignment == .leading {
            widthGuide
                .overlay(alignment: .leading) {
                    content
                }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: alignment, spacing: 0) {
            screen
                .font(.theme(.inlineToolbarTitle))
                .fontWeight(.semibold)
                .foregroundStyle(.theme(.textPrimary))
                .lineLimit(1)

            subtitle
                .font(.theme(.small))
                .foregroundStyle(.theme(.textSecondary))
        }
    }

    private var widthGuide: some View {
        // Principal items center when they fit, so an oversized invisible title claims the
        // available toolbar width before the real leading-aligned content is overlaid.
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: String(repeating: "A", count: 100))
                .font(.theme(.inlineToolbarTitle))
                .fontWeight(.semibold)
                .lineLimit(1)

            Text(verbatim: "A")
                .font(.theme(.small))
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}
