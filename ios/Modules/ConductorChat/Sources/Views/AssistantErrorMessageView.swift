//
//  SwiftUIView.swift
//  ConductorModules
//
//  Created by Gannon Prudomme on 7/26/26.
//

import ConductorDesign
import SwiftUI

struct AssistantErrorMessageView: View {
    let errorType: ErrorType
    
    init(errorMessage: String) {
        errorType = ErrorType(errorMessage)
    }
    
    var body: some View {
        if case .raw = errorType {
            rawView
        } else {
            simpleError
        }
    }
    
    var rawView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AttributedString(errorType.message))
            
            if errorType.shouldShowRetryButton {
                retryButton
            }
        }
        .padding(EdgeInsets(vertical: 12, horizontal: 16))
        .textSelection(.enabled)
        .font(.theme(.codeBody))
        .background(
            Color.theme(.destructiveBackground),
            in: .rect(cornerRadius: 26)
        )
    }
    
    var simpleError: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AttributedString(errorType.message))
            
            if errorType.shouldShowRetryButton {
                retryButton
            }
        }
        .padding(EdgeInsets(vertical: 4, horizontal: 8))
        .textSelection(.enabled)
        .font(.theme(.codeBody))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.1))
        }
        /*
        .background(
            Color.theme(.highlight),
            in: .rect(cornerRadius: 26)
        )
         */
    
    }
    
    private var retryButton: some View {
        Button("Retry") {
            
        }
//        .tint(.theme(.accent))
        .tint(.theme(.textSecondary))
        .font(.theme(.body))
    }
    
    enum ErrorType {
        case interruptedByUser
        case reconnecting(attempt: Int)
        case raw(String)
        
        init(_ string: String) {
            if string == "aborted by user" {
                self = .interruptedByUser
            } else if string.starts(with: "Reconnecting") {
                let index: String.Index = string.index(string.endIndex, offsetBy: -3)
                
                let attempt: Int? = Int(string[index...index])
                
                self = .reconnecting(attempt: attempt ?? -1)
            } else {
                self = .raw(string)
            }
        }
        
        var message: String {
            switch self {
            case .interruptedByUser:
                return "INTERRUPTED BY USER"
            case .reconnecting(let attempt):
                return "RECONNECTING... \(attempt)/5"
            case .raw(let string):
                return "Error: \(string)"
            }
        }
        
        var shouldShowRetryButton: Bool {
            return switch self {
            case .interruptedByUser:
                false
            case .reconnecting:
                false
            case .raw:
                true
            }
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        AssistantErrorMessageView(
            errorMessage: "aborted by user"
        )

        AssistantErrorMessageView(
            errorMessage: "Reconnecting... 1/5"
        )
        
        AssistantErrorMessageView(
            errorMessage: "Cannot steer: no active turn. Start a turn with runStreamed() first, or pass expectedTurnId explicitly."
        )
        
        AssistantErrorMessageView(
            errorMessage: "stream disconnected before completion: error sending request for url (https://chatgpt.com/backend-api/codex/responses)"
        )
    }
    .padding(.horizontal, 8)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(.theme(.background))
    .preferredColorScheme(.dark)
}
