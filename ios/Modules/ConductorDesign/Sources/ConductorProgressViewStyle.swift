//
//  ConductorProgressViewStyle.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/9/26.
//  100% Codex written, if you couldn't guess.
//

import SwiftUI

public struct ConductorProgressViewStyle: ProgressViewStyle {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private let phaseOffset: Double

    public init() {
        self.phaseOffset = 0
    }

    public init(phaseSeed: some Hashable) {
        // Stagger indicators that start together so they do not animate in lockstep.
        self.phaseOffset = Double(phaseSeed.hashValue.magnitude % 10_000) / 10_000
    }

    public func makeBody(configuration _: Configuration) -> some View {
        // Positions are authored in a fixed design-space canvas and scaled to fit the view.
        GeometryReader { proxy in
            let scale = min(proxy.size.width, proxy.size.height) / ProgressAnimation.canvasSize
            let origin = CGPoint(
                x: (proxy.size.width - ProgressAnimation.canvasSize * scale) / 2,
                y: (proxy.size.height - ProgressAnimation.canvasSize * scale) / 2
            )

            TimelineView(
                .animation(paused: accessibilityReduceMotion)
            ) { context in
                let frame = ProgressAnimation.frame(at: context.date, phaseOffset: phaseOffset)

                ZStack {
                    ForEach(ProgressAnimation.dots) { dot in
                        Circle()
                            .fill(.tint)
                            .frame(
                                width: ProgressAnimation.dotSize * scale,
                                height: ProgressAnimation.dotSize * scale
                            )
                            .scaleEffect(accessibilityReduceMotion ? 1 : dot.scale(at: frame))
                            .position(
                                x: origin.x + dot.position.x * scale,
                                y: origin.y + dot.position.y * scale
                            )
                    }
                }
            }
        }
    }
}

private enum ProgressAnimation {
    /// Circles per side of the square grid.
    static let gridSize = 3
    /// Distance between the centers of adjacent circles, in design-space points.
    static let spacing = 70.0
    /// Center of the first circle, which also leaves matching padding on the far edge.
    static let inset = 50.0
    static let dotSize = 40.0

    /// The design-space canvas the layout is authored in; scaled to fit the view.
    static let canvasSize = inset * 2 + spacing * Double(gridSize - 1)

    // The pulse keyframes below are authored on a fixed timeline of `frameCount` frames
    // at `authoredFrameRate` fps. This is the source animation's timebase, not the display
    // refresh rate: `TimelineView(.animation)` renders at the display's native cadence
    // (including 120 Hz ProMotion) and the scale interpolation is continuous, so playback
    // stays smooth at any refresh rate.
    static let authoredFrameRate = 60.0
    /// Total frames in one loop, so the animation resets every `frameCount / authoredFrameRate` seconds.
    static let frameCount = 64.0
    /// Frames between one circle starting its pulse and the next.
    static let stagger = 3.0
    /// Frames for a circle to scale 0 → 1 → 0.
    static let pulseDuration = 34.0

    // Pulses cascade column by column, each column running top to bottom.
    static let dots: [Dot] = (0..<gridSize).flatMap { column in
        (0..<gridSize).map { row in
            let index = column * gridSize + row
            return Dot(
                position: CGPoint(
                    x: inset + Double(column) * spacing,
                    y: inset + Double(row) * spacing
                ),
                startFrame: Double(index) * stagger
            )
        }
    }

    static func frame(at date: Date, phaseOffset: Double) -> Double {
        (date.timeIntervalSinceReferenceDate * authoredFrameRate + phaseOffset * frameCount)
            .truncatingRemainder(dividingBy: frameCount)
    }

    struct Dot: Identifiable {
        let position: CGPoint
        let startFrame: Double

        var id: Double { startFrame }

        // Scale up over the first half of the pulse and back down over the second.
        func scale(at frame: Double) -> Double {
            let elapsed = frame - startFrame
            guard elapsed >= 0, elapsed < ProgressAnimation.pulseDuration else { return 0 }

            let half = ProgressAnimation.pulseDuration / 2
            return elapsed < half
                ? UnitCurve.easeInOut.value(at: elapsed / half)
                : 1 - UnitCurve.easeInOut.value(at: (elapsed - half) / half)
        }
    }
}

public extension ProgressViewStyle where Self == ConductorProgressViewStyle {
    static var conductor: Self { Self() }

    static func conductor(phaseSeed: some Hashable) -> Self {
        Self(phaseSeed: phaseSeed)
    }
}
