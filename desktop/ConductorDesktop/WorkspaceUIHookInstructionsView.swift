//
//  WorkspaceUIHookInstructionsView.swift
//  ConductorDesktop
//
//  Created by Gannon Prudomme on 7/14/26.
//

import SharedConductorDesign
import SwiftUI

struct WorkspaceUIHookInstructionsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Workspace UI Hook")
                    .font(.theme(.heading).weight(.regular))
                    .foregroundStyle(.theme(.foreground))

                Spacer()

                Button("Done") { dismiss() }
            }

            Text(
                "The saved Console Snippet fetches the current hook from the companion each time you run it."
            )
            .font(.theme(.body))
            .foregroundStyle(.theme(.textSecondary))

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    instructions(
                        title: "First-time setup",
                        steps: [
                            "Keep the companion open and click Copy Loader.",
                            "Focus Conductor and press ⌥⌘I.",
                            "Select Sources.",
                            "Click + → Create Resource → Console Snippet.",
                            "Name it “Conductor Mobile”.",
                            "Replace the generated contents with the loader.",
                            "Select Conductor’s top-level tauri://localhost context.",
                            "Select the snippet and press Return.",
                            "Wait for Connected.",
                            "Close Web Inspector.",
                        ]
                    )

                    instructions(
                        title: "Run the saved snippet again",
                        steps: [
                            "Keep the companion open.",
                            "Open Web Inspector.",
                            "Select Sources → Console Snippets → Conductor Mobile.",
                            "Select the top-level context.",
                            "Press Return.",
                            "Wait for Connected.",
                            "Close Inspector.",
                        ]
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(28)
        .frame(width: 620, height: 620)
        .background(Color.theme(.background))
        .preferredColorScheme(.dark)
    }

    private func instructions(title: String, steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.theme(.body).weight(.medium))
                .foregroundStyle(.theme(.foreground))

            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1).")
                        .frame(width: 22, alignment: .trailing)
                    Text(step)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.theme(.small))
                .foregroundStyle(.theme(.textSecondary))
            }
        }
    }
}

#Preview("Workspace UI Hook instructions") {
    WorkspaceUIHookInstructionsView()
}
