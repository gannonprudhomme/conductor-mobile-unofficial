//
//  SpringButtonStyle.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/14/26.
//

import SwiftUI

public struct SpringButtonStyle: ButtonStyle {
    fileprivate init() { }

    public func makeBody(configuration: Configuration) -> some View {
        SpringButtonStyleBody(isPressed: configuration.isPressed) {
            configuration.label
        }
    }
}

struct SpringButtonStyleBody<Label: View>: View {
    @State private var isVisuallyPressed = false
    @State private var pressStartedAt: ContinuousClock.Instant?

    private let isPressed: Bool
    private let label: Label

    init(
        isPressed: Bool,
        @ViewBuilder label: () -> Label
    ) {
        self.isPressed = isPressed
        self.label = label()
    }

    var body: some View {
        label
            .scaleEffect(isVisuallyPressed ? 0.925 : 1) // Conductor does 0.97
            .animation(.interactiveSpring(duration: 0.150), value: isVisuallyPressed)
            .task(id: isPressed) {
                await pressedStateChanged()
            }
    }

    private func pressedStateChanged() async { // a little sloppy but it gets the job done
        let clock = ContinuousClock()
        if isPressed {
            pressStartedAt = clock.now
            isVisuallyPressed = true
            return
        }

        if let pressStartedAt {
            do {
                try await clock.sleep(
                    until: pressStartedAt.advanced(by: .milliseconds(150))
                )
            } catch {
                return
            }
        }

        guard !Task.isCancelled else {
            return
        }

        pressStartedAt = nil
        isVisuallyPressed = false
    }
}

public extension ButtonStyle where Self == SpringButtonStyle {
    static var spring: Self { Self() }
}

#Preview("Spring button variations") {
    VStack(spacing: 24) {
        Button {
        } label: {
            Text("Text button")
                .padding(EdgeInsets(vertical: 10, horizontal: 16))
                .background(.theme(.accent), in: .capsule)
        }
        .font(.theme(.body).weight(.medium))
        .foregroundStyle(.theme(.background))
        .buttonStyle(.spring)

        Button { } label: {
            Label("Button with icon", systemImage: "arrow.clockwise")
                .font(.theme(.body).weight(.medium))
                .foregroundStyle(.theme(.textPrimary))
                .padding(EdgeInsets(vertical: 10, horizontal: 16))
                .background(.theme(.muted), in: .rect(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.theme(.border))
                }
        }
        .buttonStyle(.spring)

        Button { } label: {
            Image(systemName: "heart.fill")
                .font(.theme(.heading))
                .foregroundStyle(.theme(.destructive))
                .frame(width: 48, height: 48)
                .background(.theme(.destructiveBackground), in: .circle)
        }
        .buttonStyle(.spring)
        .accessibilityLabel("Favorite")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.theme(.background))
    .preferredColorScheme(.dark)
}
