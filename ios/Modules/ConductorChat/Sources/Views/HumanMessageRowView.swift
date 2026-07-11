//
//  SwiftUIView.swift
//  ConductorModules
//
//  Created by Gannon Prudomme on 7/10/26.
//

import LucideIcons
import SwiftUI

struct HumanMessageRowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let row: Turn.Row.HumanMessageRow
    
    var body: some View {
        Text(row.content)
            .textSelection(.enabled)
            .font(.theme(.body))
            .foregroundStyle(.theme(.highlightForeground))
            .padding()
            .background(
                Color.theme(.highlight),
                in: .rect(cornerRadius: 26)
            )
            .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in
                if dynamicTypeSize.isAccessibilitySize {
                    width
                } else {
                    width * 0.75
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contextMenu {
                Button {
                    UIPasteboard.general.string = row.content
                } label: {
                    Label {
                        Text("Copy")
                            .foregroundStyle(.theme(.textPrimary))
                    } icon: {
                        Image(uiImage: Lucide.copy)
                            .renderingMode(.template)
                            .foregroundStyle(.theme(.textPrimary))
                    }
                }
                .preferredColorScheme(.dark)
            }
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 8) {
            HumanMessageRowView(
                row: Turn.Row.HumanMessageRow(
                    id: "1234",
                    content: "Content"
                )
            )
            
            HumanMessageRowView(
                row: Turn.Row.HumanMessageRow(
                    id: "12345",
                    content: "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum."
                )
            )
        }
        .padding()
    }
    .scrollContentBackground(.hidden)
    .background(.theme(.background))
    .preferredColorScheme(.dark)
}
