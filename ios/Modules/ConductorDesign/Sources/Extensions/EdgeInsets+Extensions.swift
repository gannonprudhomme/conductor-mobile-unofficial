//
//  EdgeInsets+Extensions.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SwiftUI

public extension EdgeInsets {
    init(vertical: CGFloat, horizontal: CGFloat) {
        self.init(
            top: vertical,
            leading: horizontal,
            bottom: vertical,
            trailing: horizontal
        )
    }
}
