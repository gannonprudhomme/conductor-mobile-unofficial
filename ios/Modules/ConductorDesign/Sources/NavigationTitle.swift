import SwiftUI

public extension View {
    func themedNavigationTitle(_ screen: LocalizedStringKey) -> some View {
        themedNavigationTitle(Text(screen))
    }

    func themedNavigationTitle(verbatim screen: String) -> some View {
        themedNavigationTitle(Text(verbatim: screen))
    }

    private func themedNavigationTitle(_ screen: Text) -> some View {
        navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    screen
                        .font(.theme(.inlineToolbarTitle))
                        .fontWeight(.semibold)
                }
            }
    }
}
