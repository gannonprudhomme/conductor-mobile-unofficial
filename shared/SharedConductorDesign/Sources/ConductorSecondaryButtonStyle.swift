//
//  ConductorSecondaryButtonStyle.swift
//  SharedConductorDesign
//
//  Created by Gannon Prudomme on 7/14/26.
//

import SwiftUI

public struct ConductorSecondaryButtonStyle: ButtonStyle {
    public init() { }

    public func makeBody(configuration: Configuration) -> some View {
        ConductorSecondaryButtonStyleBody(configuration: configuration)
    }
}

private struct ConductorSecondaryButtonStyleBody: View {
    let configuration: ButtonStyleConfiguration

    var body: some View {
        SpringButtonStyleBody(isPressed: configuration.isPressed) {
            configuration.label
                .labelStyle(.conductorSmall)
                .padding(EdgeInsets(vertical: 8, horizontal: 12))
                .frame(maxHeight: .infinity, alignment: .center)
                .font(.theme(.small))
                .foregroundStyle(.theme(.textPrimary))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.theme(.border))
                }
        }
    }
}

public extension ButtonStyle where Self == ConductorSecondaryButtonStyle {
    static var conductorSecondary: Self { Self() }
}
