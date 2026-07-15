//
//  SaveButton.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/14/26.
//

import SwiftUI

public struct SaveButton: View {
    @Environment(\.isEnabled) private var isEnabled

    private let action: @MainActor () -> Void

    public init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(role: .confirm, action: action)
            .tint(.theme(isEnabled ? .unread : .gray500))
    }
}
