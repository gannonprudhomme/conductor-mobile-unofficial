//
//  ConductorTextFieldStyle.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/14/26.
//

import SwiftUI

public struct ConductorTextFieldStyle: TextFieldStyle {
    @Binding private var text: String
    private let isClearButtonVisible: Bool

    public init(text: Binding<String>, isClearButtonVisible: Bool) {
        self._text = text
        self.isClearButtonVisible = isClearButtonVisible
    }

    public func _body(configuration: TextField<Self._Label>) -> some View {
        let textBinding = _text

        HStack(spacing: 8) {
            configuration

            if isClearButtonVisible, !textBinding.wrappedValue.isEmpty {
                Button {
                    textBinding.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.theme(.textSecondary))
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Clear text")
            }
        }
        .padding(EdgeInsets(vertical: 8, horizontal: 12))
        .font(.theme(.small))
        .foregroundStyle(.theme(.textPrimary))
        .tint(.theme(.accent))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.theme(.border))
        }
    }
}

public extension TextFieldStyle where Self == ConductorTextFieldStyle {
    static func conductor(
        text: Binding<String>,
        isClearButtonVisible: Bool
    ) -> Self {
        Self(text: text, isClearButtonVisible: isClearButtonVisible)
    }
}
