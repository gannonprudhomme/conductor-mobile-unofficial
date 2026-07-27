//
//  ConductorLabelStyles.swift
//  SharedConductorDesign
//
//  Created by Gannon Prudomme on 7/11/26.
//

import SwiftUI

public struct ConductorSmallLabelStyle: LabelStyle {
    fileprivate init() { }

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

public struct ConductorExtraSmallLabelStyle: LabelStyle {
    fileprivate init() { }

    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon

            configuration.title
        }
    }
}

public extension LabelStyle where Self == ConductorExtraSmallLabelStyle {
    static var conductorExtraSmall: Self { Self() }
}

public struct ConductorSettingsMenuLabelStyle: LabelStyle {
    fileprivate init() { }

    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.title

            configuration.icon
        }
        .padding(EdgeInsets(vertical: 8, horizontal: 12))
        .font(.theme(.small))
        .foregroundStyle(.theme(.textPrimary))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.theme(.border))
        }
    }
}

public extension LabelStyle where Self == ConductorSettingsMenuLabelStyle {
    static var conductorSettingsMenu: Self { Self() }
}

public struct ConductorStandardLabelStyle: LabelStyle {
    fileprivate init() { }

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
    fileprivate init() { }

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
