//
//  ChatTextFieldTests.swift
//  ConductorChatTests
//
//  Created by Gannon Prudomme on 7/17/26.
//

import ConductorVoiceInput
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
            rootView: makeChatTextField(
                text: text,
                voiceInputPhase: .idle,
                shouldFocusOnAppear: true
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

    @Test("Voice recording keeps the focused message field mounted")
    func recordingPreservesFocus() async throws {
        let text = ValueBox("")
        let model = ChatTextFieldTestModel()
        let hostingController = UIHostingController(
            rootView: ChatTextFieldTestHost(
                text: text,
                model: model
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
        _ = try #require(firstTextInputResponder(in: hostingController.view))

        model.voiceInputPhase = .recording
        await Task.yield()

        #expect(firstTextInputResponder(in: hostingController.view) != nil)
    }
}

@MainActor
private struct ChatTextFieldTestHost: View {
    let text: ValueBox<String>
    @ObservedObject var model: ChatTextFieldTestModel

    var body: some View {
        makeChatTextField(
            text: text,
            voiceInputPhase: model.voiceInputPhase,
            shouldFocusOnAppear: true
        )
    }
}

@MainActor
private final class ChatTextFieldTestModel: ObservableObject {
    @Published var voiceInputPhase = VoiceInputPhase.idle
}

@MainActor
private func makeChatTextField(
    text: ValueBox<String>,
    voiceInputPhase: VoiceInputPhase,
    shouldFocusOnAppear: Bool
) -> ChatTextField {
    ChatTextField(
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
        voiceInputPhase: voiceInputPhase,
        voiceInputLevels: [],
        selectedModel: .gpt_5_6_sol,
        selectedReasoningEffort: nil,
        availableReasoningEfforts: [],
        shouldFocusOnAppear: shouldFocusOnAppear,
        onFastModeTapped: {},
        onMicrophoneTapped: {},
        onSelectReasoningEffort: { _ in },
        onSendTapped: {},
        onStopTapped: {}
    )
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
