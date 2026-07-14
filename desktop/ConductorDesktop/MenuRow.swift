//
//  MenuRow.swift
//  ConductorDesktop
//
//  Created by Gannon Prudomme on 7/13/26.
//

import SharedConductorDesign
import SwiftUI

struct MenuRow<Content: View>: View {
    let title: Text
    let subtitle: Text?
    let content: Content

    init(
        title: Text,
        subtitle: Text? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.theme(.body).weight(.regular))
                    .foregroundStyle(.theme(.foreground))

                if let subtitle {
                    subtitle
                        .font(.theme(.small).weight(.light))
                        .foregroundStyle(.theme(.textSecondary))
                        .lineSpacing(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)

            content
        }
    }
}
