//
//  ChipButton.swift
//  ConductorDesktop
//
//  Created by Gannon Prudomme on 7/13/26.
//

import AppKit
import SharedConductorDesign
import SwiftUI

struct ChipButton: View {
    let title: String
    let icon: NSImage
    let action: @MainActor () -> Void

    @Environment(\.accessibilityReduceMotion) private var shouldReduceMotion
    @State private var isHovering = false

    var body: some View {
        Button {
            action()
        } label: {
            Label {
                AnimatedText(title)
            } icon: {
                Image(nsImage: icon)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            }
            .padding(EdgeInsets(vertical: 8, horizontal: 12))
            .labelStyle(.conductorSmall)
            .font(.theme(.small).weight(.light))
            .foregroundStyle(.theme(.foreground))
            .background(
                isHovering ? .theme(.controlHover) : .theme(.background),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.theme(.border), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(animation, value: title)
        .animation(animation, value: icon)
    }

    private var animation: Animation? {
        shouldReduceMotion ? nil : .easeOut(duration: 0.24)
    }
}
