import SwiftUI

public extension View {
    func themedNavigationTitle(_ screen: LocalizedStringKey) -> some View {
        navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(screen)
                        .font(.theme(.inlineToolbarTitle))
                        .fontWeight(.semibold)
                }
            }
    }
}
