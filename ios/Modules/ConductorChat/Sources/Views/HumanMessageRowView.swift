//
//  SwiftUIView.swift
//  ConductorModules
//
//  Created by Gannon Prudomme on 7/10/26.
//

import LucideIcons
import SwiftUI

struct HumanMessageRowView: View {
    let row: Turn.Row.HumanMessageRow
    let screenWidth: CGFloat
    
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
            .frame(maxWidth: screenWidth * 0.75, alignment: .trailing)
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
    @Previewable @State var screenWidth: CGFloat = 0
    
    ScrollView {
        VStack(spacing: 8) {
            HumanMessageRowView(
                row: Turn.Row.HumanMessageRow(
                    id: "1234",
                    content: "Content"
                ),
                screenWidth: screenWidth
            )
            
            HumanMessageRowView(
                row: Turn.Row.HumanMessageRow(
                    id: "12345",
                    content: "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum."
                ),
                screenWidth: screenWidth
            )
        }
        .padding()
    }
    .scrollContentBackground(.hidden)
    .background(.theme(.background))
    .readSize { size in
        screenWidth = size.width
    }
    .preferredColorScheme(.dark)
}
