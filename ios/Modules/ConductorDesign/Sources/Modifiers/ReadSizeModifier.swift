//
//  ReadSizeModifier.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/10/26.
//

import SwiftUI

public struct ReadSizeModifier: ViewModifier {
    let onSizeChange: (CGSize) -> Void

    public func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            onSizeChange(geometry.size)
                        }
                        .onChange(of: geometry.size) { _, newSize in
                            onSizeChange(newSize)
                        }
                }
            }
    }
}

extension View {
    public func readSize(perform action: @escaping (CGSize) -> Void) -> some View {
        self.modifier(ReadSizeModifier(onSizeChange: action))
    }
}
