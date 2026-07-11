//
//  ConductorLabelStyles.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/11/26.
//

import SwiftUI

public struct ConductorSmallLabelStyle: LabelStyle {
    public init() { }

    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon

            configuration.title
        }
    }
}

public extension LabelStyle where Self == ConductorSmallLabelStyle {
    static var conductorSmall: Self { Self() }
}

public struct ConductorStandardLabelStyle: LabelStyle {
    public init() { }

    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                configuration.icon
            }

            configuration.title
        }
    }
}

public extension LabelStyle where Self == ConductorStandardLabelStyle {
    static var conductorStandard: Self { Self() }
}

public struct ConductorStandardLabeledContentStyle: LabeledContentStyle {
    public init() { }

    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) {
            configuration.label

            Spacer(minLength: 12)

            HStack(spacing: 12) {
                configuration.content
            }
        }
    }
}

public extension LabeledContentStyle where Self == ConductorStandardLabeledContentStyle {
    static var conductorStandard: Self { Self() }
}
