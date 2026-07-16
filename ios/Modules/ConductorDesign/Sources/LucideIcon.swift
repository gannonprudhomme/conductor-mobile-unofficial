//
//  LucideIcon.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/11/26.
//

import SwiftUI

// TODO: Move to ModelPicker.swift
import SharedConductorData
import SharedConductorDesign
// import SwiftUI

public struct ChatConfigMenusView: View {
    let agentType: Session.AgentType
    let model: Session.Model
    
    public init(agentType: Session.AgentType, model: Session.Model) {
        self.agentType = agentType
        self.model = model
    }
    
    public var body: some View {
        HStack(spacing: 8) {
            menuLabel
        }
    }
    
    private var menuLabel: some View {
        Label {
            Text(verbatim: model.displayName)
        } icon: {
            AgentIcon(
                agentType: agentType,
                size: ThemeFontStyle.small.size,
                relativeTo: ThemeFontStyle.small.textStyle
            )
        }
        .labelStyle(.conductorExtraSmall)
        .foregroundStyle(.theme(.textPrimary))
        .font(.theme(.small))
    }
    
    private var fastModeButton: some View {
        Button {
            
        } label: {
            Label {
                
            } icon: {
                
            }
        }
        .buttonStyle(.spring)
    }
}

public struct LucideIcon: View {
    @ScaledMetric private var size: CGFloat

    private let image: UIImage

    public init(
        _ image: UIImage,
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle
    ) {
        self.image = image
        self._size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
    }

    public init(_ image: UIImage, style: ThemeFontStyle) {
        self.init(
            image,
            size: style.size,
            relativeTo: style.textStyle
        )
    }

    public var body: some View {
        Image(uiImage: image)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
