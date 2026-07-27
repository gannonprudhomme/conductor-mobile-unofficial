//
//  CloudWorkspaceIcon.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/24/26.
//

import SwiftUI

public struct CloudWorkspaceIcon: View {
    private let size: CGFloat

    public init(size: CGFloat) {
        self.size = size
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let columnsByRow = [
                [2, 3],
                [1, 2, 3, 4],
                [0, 1, 2, 3, 4, 5],
                [1, 2, 3, 4, 5, 6],
            ]
            let step = canvasSize.width / 7
            let dotSize = step * 0.6
            let originY = (canvasSize.height - step * 4) / 2

            for (row, columns) in columnsByRow.enumerated() {
                for column in columns {
                    let dot = CGRect(
                        x: (CGFloat(column) + 0.5) * step - dotSize / 2,
                        y: originY + (CGFloat(row) + 0.5) * step - dotSize / 2,
                        width: dotSize,
                        height: dotSize
                    )
                    context.fill(
                        Path(roundedRect: dot, cornerRadius: dotSize / 4),
                        with: .foreground
                    )
                }
            }
        }
        .frame(width: size, height: size)
    }
}
