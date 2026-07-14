//
//  StatusTag.swift
//  ConductorDesktop
//
//  Created by Gannon Prudomme on 7/13/26.
//

import SharedConductorDesign
import SwiftUI

struct StatusTag: View {
    let title: String
    let isEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var shouldReduceMotion

    var body: some View {
        AnimatedText(title)
            .font(.theme(.extraSmall))
            .foregroundStyle(color)
            .padding(EdgeInsets(vertical: 2.5, horizontal: 8.5))
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
            .animation(animation, value: isEnabled)
    }

    private var color: Color {
        isEnabled ? .theme(.success) : .theme(.destructive)
    }

    private var backgroundColor: Color {
        isEnabled
            ? .theme(.successBackground)
            : .theme(.destructiveBackground)
    }

    private var borderColor: Color {
        isEnabled
            ? .theme(.successBorder)
            : .theme(.destructiveBorder)
    }

    private var animation: Animation? {
        shouldReduceMotion ? nil : .easeOut(duration: 0.24)
    }
}
