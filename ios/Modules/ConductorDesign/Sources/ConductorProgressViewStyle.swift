//
//  ConductorProgressViewStyle.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/9/26.
//  100% Codex written, if you couldn't guess.
//

import SwiftUI

public struct ConductorProgressViewStyle: ProgressViewStyle {
    public enum Variant: Sendable {
        case `default`
        case random
    }

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private let variant: Variant
    private let phaseOffset: Double

    fileprivate init(
        _ variant: Variant = .default,
        phaseOffset: Double = 0
    ) {
        self.variant = variant
        self.phaseOffset = phaseOffset
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
                let frame = ProgressAnimation.frame(
                    at: context.date,
                    variant: variant,
                    phaseOffset: phaseOffset
                )

                ZStack {
                    ForEach(ProgressAnimation.dots) { dot in
                        let dotScale = ProgressAnimation.scale(
                            of: dot,
                            at: frame,
                            variant: variant
                        )

                        Circle()
                            .fill(.tint)
                            .frame(
                                width: ProgressAnimation.dotSize * scale,
                                height: ProgressAnimation.dotSize * scale
                            )
                            .scaleEffect(accessibilityReduceMotion ? 1 : dotScale)
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

    // The pulse keyframes below are authored on a fixed timeline at `authoredFrameRate`
    // fps. This is the source animation's timebase, not the display
    // refresh rate: `TimelineView(.animation)` renders at the display's native cadence
    // (including 120 Hz ProMotion) and the scale interpolation is continuous, so playback
    // stays smooth at any refresh rate.
    static let authoredFrameRate = 60.0
    static let defaultFrameCount = 64.0
    /// Frames between one circle starting its pulse and the next.
    static let stagger = 3.0
    /// Frames for a circle to scale 0 → 1 → 0.
    static let pulseDuration = 34.0

    // Pulses cascade column by column, each column running top to bottom.
    static let dots: [Dot] = (0..<gridSize).flatMap { column in
        (0..<gridSize).map { row in
            let index = column * gridSize + row
            return Dot(
                id: index,
                position: CGPoint(
                    x: inset + Double(column) * spacing,
                    y: inset + Double(row) * spacing
                )
            )
        }
    }

    static func frame(
        at date: Date,
        variant: ConductorProgressViewStyle.Variant,
        phaseOffset: Double
    ) -> Double {
        let loopFrameCount = switch variant {
        case .default:
            defaultFrameCount
        case .random:
            Double(randomFrameCount)
        }
        let elapsed = date.timeIntervalSinceReferenceDate * authoredFrameRate
            + phaseOffset * loopFrameCount
        return elapsed.truncatingRemainder(dividingBy: loopFrameCount)
    }

    static func scale(
        of dot: Dot,
        at frame: Double,
        variant: ConductorProgressViewStyle.Variant
    ) -> Double {
        switch variant {
        case .default:
            defaultPulseScale(elapsed: frame - Double(dot.id) * stagger)
        case .random:
            randomScale(of: dot, at: frame)
        }
    }

    private static func defaultPulseScale(elapsed: Double) -> Double {
        guard elapsed >= 0, elapsed < pulseDuration else {
            return 0
        }

        let half = pulseDuration / 2
        return elapsed < half
            ? UnitCurve.easeInOut.value(at: elapsed / half)
            : 1 - UnitCurve.easeInOut.value(at: (elapsed - half) / half)
    }

    private static let randomFrameCount = 640
    private static let randomScales = NSDataAsset(
        name: "ConductorProgressRandom",
        bundle: #bundle
    ).flatMap {
        Data(base64Encoded: $0.data, options: .ignoreUnknownCharacters)
    }

    private static func randomScale(of dot: Dot, at frame: Double) -> Double {
        guard let randomScales,
              randomScales.count == randomFrameCount * dots.count else {
            return 0
        }

        let lowerFrame = Int(frame.rounded(.down))
        let upperFrame = (lowerFrame + 1) % randomFrameCount
        let progress = frame - Double(lowerFrame)
        let lowerScale = Double(randomScales[lowerFrame * dots.count + dot.id]) / 255
        let upperScale = Double(randomScales[upperFrame * dots.count + dot.id]) / 255
        return lowerScale + (upperScale - lowerScale) * progress
    }

    struct Dot: Identifiable {
        let id: Int
        let position: CGPoint
    }
}

public extension ProgressViewStyle where Self == ConductorProgressViewStyle {
    static var conductor: Self { Self() }

    static func conductor(_ variant: ConductorProgressViewStyle.Variant) -> Self {
        Self(variant)
    }

    static func conductor(phaseSeed: some Hashable) -> Self {
        Self(
            // Stagger indicators that start together so they do not animate in lockstep.
            phaseOffset: Double(phaseSeed.hashValue.magnitude % 10_000) / 10_000
        )
    }
}
