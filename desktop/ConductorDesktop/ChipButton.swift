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
    // A little sloppy, this should come from elsewhere, but eh might as well
    var isConfirmed = false
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
            // Overlay confirmation so swapping to the check never changes the button's width.
            .opacity(isConfirmed ? 0 : 1)
            .overlay {
                Image(nsImage: Lucide.check)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .opacity(isConfirmed ? 1 : 0)
                    .accessibilityHidden(true)
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
        .buttonStyle(.spring)
        .accessibilityLabel(title)
        .onHover { isHovering = $0 }
        .animation(animation, value: title)
        .animation(animation, value: icon)
        .animation(confirmationAnimation, value: isConfirmed)
    }

    private var animation: Animation? {
        shouldReduceMotion ? nil : .easeOut(duration: 0.24)
    }

    private var confirmationAnimation: Animation? {
        shouldReduceMotion ? nil : .easeInOut(duration: 0.15)
    }
}
