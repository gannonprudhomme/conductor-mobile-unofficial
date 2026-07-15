//
//  ConductorMenuPicker.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/15/26.
//

import LucideIcons
import SwiftUI

public struct ConductorMenuPicker<Value: Hashable, Content: View>: View {
    private let values: [Value]
    @Binding private var selection: Value
    private let content: (Value) -> Content

    public init(
        _ values: [Value],
        selection: Binding<Value>,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.values = values
        _selection = selection
        self.content = content
    }

    public var body: some View {
        ForEach(values, id: \.self) { value in
            Button {
                selection = value
            } label: {
                if selection == value {
                    Label {
                        content(value)
                    } icon: {
                        ColoredMenuImage(
                            Lucide.check,
                            color: .theme(.textPrimary)
                        )
                    }
                } else {
                    content(value)
                }
            }
        }
    }
}
