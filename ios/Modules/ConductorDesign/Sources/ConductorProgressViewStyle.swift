//
//  ConductorProgressViewStyle.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Lottie
import SwiftUI

public struct ConductorProgressViewStyle: ProgressViewStyle {
    private let phaseOffset: Double

    public init() {
        self.phaseOffset = 0
    }

    public init(phaseSeed: some Hashable) {
        // Stagger indicators that start together so they do not animate in lockstep.
        self.phaseOffset = Double(phaseSeed.hashValue.magnitude % 10_000) / 10_000
    }

    public func makeBody(configuration: Configuration) -> some View {
        Group {
            if let animation = Self.animation {
                LottieView(animation: animation)
                    .looping()
                    .configure { animationView in
                        animationView.layer.timeOffset = animation.duration * phaseOffset
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
            }
        }
    }

    private static let animation: LottieAnimation? = {
        guard let data = NSDataAsset(name: "ConductorProgress", bundle: #bundle)?.data
        else { return nil }
        return try? LottieAnimation.from(data: data)
    }()
}

public extension ProgressViewStyle where Self == ConductorProgressViewStyle {
    static var conductor: Self { Self() }

    /// Really just exists so we can prevent having a bunch of these be synchronized on the `Workspaces` list view
    static func conductor(phaseSeed: some Hashable) -> Self {
        Self(phaseSeed: phaseSeed)
    }
}
