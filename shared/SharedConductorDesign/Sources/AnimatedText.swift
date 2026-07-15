//
//  AnimatedText.swift
//  SharedConductorDesign
//
//  Created by Gannon Prudomme on 7/13/26.
//

import SwiftUI

// Purely Codex written. Came from Codex trying to replicate the text-change animation I had in React
//
// Honestly I should probably remove this but for the size of this desktop portion is this is fine,
// it's pretty much my only slop on the desktop+Swift side.
public struct AnimatedText: View {
    let title: String

    @Environment(\.accessibilityReduceMotion) private var shouldReduceMotion
    @State private var displayedTitle: String
    @State private var opacity = 1.0
    @State private var width: CGFloat?
    @State private var fadeTask: Task<Void, Never>?

    public init(_ title: String) {
        self.title = title
        _displayedTitle = State(initialValue: title)
    }

    public var body: some View {
        Text(displayedTitle)
            .fixedSize()
            .opacity(opacity)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.width
            } action: { newWidth in
                if width == nil || shouldReduceMotion {
                    width = newWidth
                } else {
                    withAnimation(.easeOut(duration: 0.24)) {
                        width = newWidth
                    }
                }
            }
            .frame(width: width, alignment: .leading)
            .clipped()
            .onChange(of: title) { _, newTitle in
                titleChanged(newTitle)
            }
            .onDisappear {
                fadeTask?.cancel()
            }
    }

    private func titleChanged(_ newTitle: String) {
        fadeTask?.cancel()
        displayedTitle = newTitle

        guard !shouldReduceMotion else {
            opacity = 1
            return
        }

        opacity = 0
        fadeTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else {
                return
            }
            withAnimation(.easeOut(duration: 0.24)) {
                opacity = 1
            }
        }
    }
}
