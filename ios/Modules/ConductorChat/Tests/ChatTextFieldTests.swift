//
//  ChatTextFieldTests.swift
//  ConductorChatTests
//
//  Created by Gannon Prudomme on 7/17/26.
//

import SharedConductorData
import SwiftUI
@testable import ConductorChat
import Testing
import UIKit

@MainActor
struct ChatTextFieldTests {
    @Test("A newly created chat focuses and edits its message field")
    func focusesAndEditsOnAppear() async throws {
        let text = ValueBox("")
        let hostingController = UIHostingController(
            rootView: ChatTextField(
                text: Binding(
                    get: { text.value },
                    set: { text.value = $0 }
                ),
                agentType: .codex,
                allowsAgentSwitching: true,
                isFastModeEnabled: false,
                isSendInFlight: false,
                isStopInFlight: false,
                isWorking: false,
                selectedModel: .constant(.gpt_5_6_sol),
                shouldFocusOnAppear: true,
                onFastModeTapped: {},
                onSendTapped: {},
                onStopTapped: {}
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while firstTextInputResponder(in: hostingController.view) == nil,
              clock.now < deadline {
            await Task.yield()
        }

        let responder = try #require(firstTextInputResponder(in: hostingController.view))
        responder.insertText("Test message")

        while text.value != "Test message", clock.now < deadline {
            await Task.yield()
        }
        #expect(text.value == "Test message")
    }
}

@MainActor
private func firstTextInputResponder(in view: UIView) -> (UIView & UIKeyInput)? {
    if view.isFirstResponder, let textInput = view as? UIView & UIKeyInput {
        return textInput
    }
    for subview in view.subviews {
        if let responder = firstTextInputResponder(in: subview) {
            return responder
        }
    }
    return nil
}

@MainActor
private final class ValueBox<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
