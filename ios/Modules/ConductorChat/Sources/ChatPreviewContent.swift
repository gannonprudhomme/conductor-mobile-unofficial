//
//  ChatPreviewContent.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/12/26.
//

#if DEBUG
import SharedConductorData
import Foundation

struct ChatPreviewContent: Sendable {
    let messages: [Message]
    let session: Session

    init() throws {
        self.session = .preview(
            id: "preview-session",
            workspaceID: "preview-workspace",
            title: "Fix weather card conditions",
            updatedAt: "2026-06-25T09:31:39.000Z",
            lastUserMessageAt: "2026-06-25T09:31:28.000Z",
            contextTokenCount: 18420
        )

        var builder = TranscriptBuilder()
        for (index, turn) in Self.turns.enumerated() {
            builder.append(turn: turn, number: index + 1)
        }
        self.messages = try JSONDecoder.conductor.decode(
            [Message].self,
            from: JSONEncoder().encode(builder.rows)
        )
    }

    static func shortMessages(
        for session: Session,
        userMessage: String,
        assistantMessage: String
    ) throws -> [Message] {
        let turnID = "\(session.id)-preview-turn"
        let rows = [
            MessageFixture(
                id: "\(session.id)-preview-user-message",
                sessionID: session.id,
                role: "user",
                content: userMessage,
                createdAt: session.createdAt,
                sentAt: session.createdAt,
                model: nil,
                sdkMessageID: nil,
                turnID: turnID
            ),
            MessageFixture(
                id: "\(session.id)-preview-assistant-message",
                sessionID: session.id,
                role: "assistant",
                content: assistantTextEvent(assistantMessage, sessionID: session.id),
                createdAt: session.updatedAt,
                sentAt: session.updatedAt,
                model: session.model,
                sdkMessageID: "\(session.id)-preview-sdk-message",
                turnID: turnID
            ),
        ]
        return try JSONDecoder.conductor.decode(
            [Message].self,
            from: JSONEncoder().encode(rows)
        )
    }
}

private extension ChatPreviewContent {
    static let turns = [
        TurnFixture(
            user: """
            Why can't I see “Cloudy” or “Sunny” below the temperature? Is something broken?

            @⟦weather-card.png⟧(.context%2Fattachments%2Fpreview%2Fweather-card.png)
            """,
            progress: [
                "I’ll trace the condition label from the model through the SwiftUI view, then compare it with the screenshot.",
                "The API value is present. The view is hiding it because the condition text shares a fixed-height overlay with the temperature.",
                """
                ## What I found

                The weather data is fine. `WeatherCardView` clips the second line before it can render.

                - The model contains `Cloudy`.
                - The accessibility label also contains it.
                - Only the visible stack has a fixed height.

                > No files changed yet.
                """,
            ],
            tools: [
                .bash(
                    command: "pwd && rg -n \"condition|temperature\" ios/WeatherDemo",
                    output: "ios/WeatherDemo/WeatherCardView.swift:18: Text(model.temperature)\nios/WeatherDemo/WeatherCardView.swift:22: Text(model.condition)"
                ),
                .read(
                    path: "ios/WeatherDemo/WeatherCardView.swift",
                    output: "struct WeatherCardView: View {\n    let model: WeatherCardModel\n    var body: some View {\n        VStack(spacing: 16) {\n            Text(model.temperature)\n        }\n    }\n}"
                ),
                .grep(
                    pattern: "condition",
                    path: "ios/WeatherDemo",
                    output: "WeatherCardModel.swift:9: let condition: String\nWeatherCardView.swift:22: Text(model.condition)\nWeatherCardTests.swift:31: condition: \"Cloudy\""
                ),
                .bash(
                    command: "git status --short",
                    output: ""
                ),
                .bash(
                    command: "git log -5 --oneline -- ios/WeatherDemo/WeatherCardView.swift",
                    output: "ab12cd3 Tighten weather card layout\n98ef765 Add condition accessibility label"
                ),
            ]
        ),
        TurnFixture(
            user: "Fix it, and keep the change limited to the card layout.",
            progress: [
                "I’ll remove the conflicting height constraint and keep the existing typography and data flow intact.",
                """
                Fixed the weather condition label in `WeatherCardView.swift`.

                ```swift
                VStack(spacing: 8) {
                    Text(model.temperature)
                    Text(model.condition)
                }
                ```

                The card now shows both lines without changing the model or networking code.
                """,
            ],
            tools: [
                .read(
                    path: "ios/WeatherDemo/WeatherCardView.swift",
                    output: "VStack(spacing: 16) {\n    Text(model.temperature)\n    Text(model.condition)\n}\n.frame(height: 28)"
                ),
                .bash(
                    command: "rg -n \"frame\\(height: 28\\)\" ios/WeatherDemo",
                    output: "ios/WeatherDemo/WeatherCardView.swift:24: .frame(height: 28)"
                ),
                .edit(
                    path: "ios/WeatherDemo/WeatherCardView.swift",
                    old: "VStack(spacing: 16) {\n    Text(model.temperature)\n    Text(model.condition)\n}\n.frame(height: 28)",
                    new: "VStack(spacing: 8) {\n    Text(model.temperature)\n    Text(model.condition)\n}"
                ),
                .bash(
                    command: "xcodebuild build -scheme WeatherDemo -destination 'generic/platform=iOS Simulator'",
                    output: "** BUILD SUCCEEDED **"
                ),
            ]
        ),
        TurnFixture(
            user: "Check the card at compact and accessibility text sizes too.",
            progress: [
                "I’ll exercise the existing preview variants and verify that neither line truncates at the supported Dynamic Type sizes.",
                """
                The card is stable in the compact and accessibility previews.

                1. Compact width keeps the condition on one line.
                2. Accessibility sizes allow the stack to grow vertically.
                3. VoiceOver still reads the temperature before the condition.
                """,
            ],
            tools: [
                .bash(
                    command: "rg -n \"Preview|dynamicTypeSize\" ios/WeatherDemo",
                    output: "ios/WeatherDemo/WeatherCardView.swift:52:#Preview(\"Compact\")\nios/WeatherDemo/WeatherCardView.swift:61:#Preview(\"Accessibility\")"
                ),
                .bash(
                    command: "xcodebuild build -scheme WeatherDemo -destination 'platform=iOS Simulator,name=iPhone 17 Pro'",
                    output: "** BUILD SUCCEEDED **"
                ),
                .bash(
                    command: "xcodebuild test -scheme WeatherDemoTests -only-testing:WeatherDemoTests/WeatherCardLayoutTests",
                    output: "Test Suite 'WeatherCardLayoutTests' passed\nExecuted 3 tests, with 0 failures"
                ),
                .bash(
                    command: "git diff --check",
                    output: ""
                ),
            ]
        ),
        TurnFixture(
            user: "The preview still jumps when the condition changes. Can you stabilize the layout?",
            progress: [
                "I’ll compare short, long, and missing conditions and reserve only the space the secondary line actually needs.",
                """
                The preview no longer jumps between weather states. The secondary label now reserves one text line while the card remains free to grow for accessibility sizes.

                > The fix stays in the view; no placeholder condition is added to the model.
                """,
            ],
            tools: [
                .read(
                    path: "ios/WeatherDemo/WeatherCardView.swift",
                    output: "Text(model.condition)\n    .font(.weather(.condition))\n    .foregroundStyle(.weather(.secondaryText))"
                ),
                .bash(
                    command: "rg -n \"lineLimit|reservesSpace\" ios/WeatherDemo",
                    output: "ios/WeatherDemo/ForecastRow.swift:38: .lineLimit(1, reservesSpace: true)"
                ),
                .edit(
                    path: "ios/WeatherDemo/WeatherCardView.swift",
                    old: "Text(model.condition)\n    .font(.weather(.condition))",
                    new: "Text(model.condition)\n    .font(.weather(.condition))\n    .lineLimit(1, reservesSpace: true)"
                ),
                .bash(
                    command: "xcodebuild test -scheme WeatherDemoTests -only-testing:WeatherDemoTests/WeatherCardLayoutTests",
                    output: "Test Suite 'WeatherCardLayoutTests' passed\nExecuted 4 tests, with 0 failures"
                ),
            ],
            systemStatus: "Compacting context"
        ),
        TurnFixture(
            user: """
            @⟦empty-condition.png⟧(.context%2Fattachments%2Fpreview%2Fempty-condition.png)

            This is the empty state. Please add a focused regression test for it.
            """,
            progress: [
                "I’ll cover the empty condition directly so the reserved line remains intentional and future layout changes cannot collapse it.",
                """
                Added a focused empty-condition regression test. It verifies that the card keeps a stable height and exposes only the temperature to accessibility when the condition is empty.
                """,
            ],
            tools: [
                .bash(
                    command: "rg -n \"WeatherCardLayoutTests\" ios/WeatherDemoTests",
                    output: "ios/WeatherDemoTests/WeatherCardLayoutTests.swift:4:struct WeatherCardLayoutTests"
                ),
                .read(
                    path: "ios/WeatherDemoTests/WeatherCardLayoutTests.swift",
                    output: "import Testing\n@testable import WeatherDemo\n\nstruct WeatherCardLayoutTests {\n    @Test func cloudyCondition() {\n        #expect(makeCard(condition: \"Cloudy\").height > 0)\n    }\n}"
                ),
                .grep(
                    pattern: "condition: \"\"",
                    path: "ios",
                    output: "ios/WeatherDemo/PreviewData.swift:27: condition: \"\""
                ),
                .bash(
                    command: "xcodebuild test -scheme WeatherDemoTests -only-testing:WeatherDemoTests/WeatherCardLayoutTests/emptyCondition",
                    output: "Test case 'emptyCondition' passed (0.014 seconds)"
                ),
            ]
        ),
        TurnFixture(
            user: "Run the relevant tests and clean up anything obvious.",
            progress: [
                "I’ll run the narrow suite first, address any fixture mismatch, then finish with formatting and a clean diff check.",
                """
                All relevant checks pass:

                - 5 weather card layout tests
                - Debug simulator build
                - Formatting and whitespace checks

                I also renamed the test helper to match the existing `makeSUT` convention.
                """,
            ],
            tools: [
                .bash(
                    command: "xcodebuild test -scheme WeatherDemoTests -only-testing:WeatherDemoTests/WeatherCardLayoutTests",
                    output: "Executed 5 tests, with 0 failures"
                ),
                .bash(
                    command: "swift test --filter WeatherCardTests",
                    output: "error: no tests found matching 'WeatherCardTests'",
                    isError: true
                ),
                .edit(
                    path: "ios/WeatherDemoTests/WeatherCardLayoutTests.swift",
                    old: "private func makeCard(condition: String)",
                    new: "private func makeSUT(condition: String)"
                ),
                .bash(
                    command: "git diff --check && swift format lint -r ios/WeatherDemo ios/WeatherDemoTests",
                    output: "Linting Swift files\n0 issues found"
                ),
            ]
        ),
        TurnFixture(
            user: "Review the diff before we commit. Anything risky?",
            progress: [
                "I’ll review the final patch for behavior changes, accessibility regressions, and anything outside the requested scope.",
                """
                ## Review

                I don’t see a blocking issue.

                - The production change is two view modifiers.
                - Empty conditions do not create a spoken blank label.
                - The tests cover short, long, and empty values.

                The only trade-off is intentional: non-accessibility sizes reserve one line even when the condition is empty.
                """,
            ],
            tools: [
                .read(
                    path: "ios/WeatherDemo/WeatherCardView.swift",
                    output: "Text(model.condition)\n    .font(.weather(.condition))\n    .lineLimit(1, reservesSpace: true)\n    .foregroundStyle(.weather(.secondaryText))"
                ),
                .bash(
                    command: "git diff --stat",
                    output: "ios/WeatherDemo/WeatherCardView.swift | 3 ++-\nios/WeatherDemoTests/WeatherCardLayoutTests.swift | 18 ++++++++++++++++++\n2 files changed, 20 insertions(+), 1 deletion(-)"
                ),
                .bash(
                    command: "git diff -- ios/WeatherDemo/WeatherCardView.swift ios/WeatherDemoTests/WeatherCardLayoutTests.swift",
                    output: "diff --git a/WeatherCardView.swift b/WeatherCardView.swift\n+    .lineLimit(1, reservesSpace: true)\n+@Test func emptyCondition()"
                ),
                .bash(
                    command: "git status --short",
                    output: " M ios/WeatherDemo/WeatherCardView.swift\n M ios/WeatherDemoTests/WeatherCardLayoutTests.swift"
                ),
            ]
        ),
        TurnFixture(
            user: "Commit these changes, but don't push yet. Then give me the short summary.",
            progress: [
                "I’ll make one focused commit with the verified view and regression-test changes, and I’ll leave the branch local.",
                """
                Committed as `4f3c2b1` (`Show weather condition in cards`). Nothing was pushed.

                **Summary:** the weather card now displays its condition, remains stable for empty values, and has focused layout coverage.
                """,
            ],
            tools: [
                .bash(
                    command: "git diff --check && git status --short",
                    output: " M ios/WeatherDemo/WeatherCardView.swift\n M ios/WeatherDemoTests/WeatherCardLayoutTests.swift"
                ),
                .read(
                    path: "ios/WeatherDemoTests/WeatherCardLayoutTests.swift",
                    output: "@Test func emptyCondition() {\n    let card = makeSUT(condition: \"\")\n    #expect(card.reservesConditionLine)\n}"
                ),
                .bash(
                    command: "git add ios/WeatherDemo/WeatherCardView.swift ios/WeatherDemoTests/WeatherCardLayoutTests.swift && git commit -m 'Show weather condition in cards'",
                    output: "[weather-card 4f3c2b1] Show weather condition in cards\n2 files changed, 20 insertions(+), 1 deletion(-)"
                ),
                .bash(
                    command: "git status --short --branch",
                    output: "## weather-card"
                ),
            ]
        ),
    ]
}

private struct TurnFixture {
    let user: String
    let progress: [String]
    let tools: [ToolFixture]
    var systemStatus: String? = nil
}

private struct ToolFixture {
    let name: String
    let thinking: String
    let input: [String: String]
    let result: String
    let isError: Bool

    static func bash(
        command: String,
        output: String,
        isError: Bool = false
    ) -> Self {
        Self(
            name: "Bash",
            thinking: "Run a focused shell command and inspect its output.",
            input: ["command": command],
            result: output,
            isError: isError
        )
    }

    static func read(path: String, output: String) -> Self {
        Self(
            name: "Read",
            thinking: "Read the relevant source before deciding what to change.",
            input: ["file_path": path],
            result: output,
            isError: false
        )
    }

    static func grep(pattern: String, path: String, output: String) -> Self {
        Self(
            name: "Grep",
            thinking: "Search for every use so the change stays consistent.",
            input: [
                "path": path,
                "pattern": pattern,
            ],
            result: output,
            isError: false
        )
    }

    static func edit(
        path: String,
        old: String,
        new: String
    ) -> Self {
        Self(
            name: "Edit",
            thinking: "Apply the smallest source edit that addresses the request.",
            input: [
                "file_path": path,
                "new_string": new,
                "old_string": old,
            ],
            result: "Updated \(path)",
            isError: false
        )
    }
}

private struct TranscriptBuilder {
    private(set) var rows: [MessageFixture] = []
    private var nextMessageNumber = 1

    mutating func append(turn: TurnFixture, number: Int) {
        precondition(turn.progress.count >= 2)
        let turnID = "preview-turn-\(number)"
        append(
            id: turnID,
            role: "user",
            content: turn.user,
            turnID: turnID
        )
        appendAssistantText(turn.progress[0], turnID: turnID)

        for (index, tool) in turn.tools.enumerated() {
            let toolID = "preview-tool-\(number)-\(index + 1)"
            append(
                role: "assistant",
                content: assistantToolEvent(tool, id: toolID),
                turnID: turnID
            )
            if index == 1, let systemStatus = turn.systemStatus {
                append(
                    role: "assistant",
                    content: systemEvent(systemStatus),
                    turnID: turnID
                )
            }
            append(
                role: "assistant",
                content: toolResultEvent(tool, id: toolID),
                turnID: turnID
            )
            if index == 1 {
                for progress in turn.progress.dropFirst().dropLast() {
                    appendAssistantText(progress, turnID: turnID)
                }
            }
        }

        appendAssistantText(turn.progress.last!, turnID: turnID)
        append(
            role: "assistant",
            content: resultEvent(turnNumber: number),
            turnID: turnID
        )
    }

    private mutating func appendAssistantText(_ text: String, turnID: String) {
        append(
            role: "assistant",
            content: assistantTextEvent(text),
            turnID: turnID
        )
    }

    private mutating func append(
        id: String? = nil,
        role: String,
        content: String,
        turnID: String
    ) {
        let number = nextMessageNumber
        let timestamp = String(
            format: "2026-06-25T09:%02d:%02d.000Z",
            30 + (number - 1) / 60,
            (number - 1) % 60
        )
        rows.append(
            MessageFixture(
                id: id ?? String(format: "preview-message-%03d", number),
                sessionID: "preview-session",
                role: role,
                content: content,
                createdAt: timestamp,
                sentAt: timestamp,
                model: role == "assistant" ? "gpt-5" : nil,
                sdkMessageID: role == "assistant"
                    ? String(format: "preview-sdk-%03d", number)
                    : nil,
                turnID: turnID
            )
        )
        nextMessageNumber += 1
    }
}

private struct MessageFixture: Encodable {
    let id: String
    let sessionID: String
    let role: String
    let content: String
    let createdAt: String
    let sentAt: String
    let model: String?
    let sdkMessageID: String?
    let turnID: String

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case role
        case content
        case createdAt = "created_at"
        case sentAt = "sent_at"
        case model
        case sdkMessageID = "sdk_message_id"
        case turnID = "turn_id"
    }
}

private func assistantTextEvent(
    _ text: String,
    sessionID: Session.ID = "preview-session"
) -> String {
    """
    {"type":"assistant","session_id":\(json(sessionID)),"message":{"role":"assistant","content":[{"type":"text","text":\(json(text))}]}}
    """
}

private func assistantToolEvent(_ tool: ToolFixture, id: String) -> String {
    """
    {"type":"assistant","session_id":"preview-session","message":{"role":"assistant","content":[{"type":"thinking","thinking":\(json(tool.thinking))},{"type":"tool_use","id":\(json(id)),"name":\(json(tool.name)),"input":\(json(tool.input))}]}}
    """
}

private func toolResultEvent(_ tool: ToolFixture, id: String) -> String {
    """
    {"type":"user","session_id":"preview-session","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":\(json(id)),"content":\(json(tool.result)),"is_error":\(tool.isError)}]}}
    """
}

private func systemEvent(_ message: String) -> String {
    """
    {"type":"system","session_id":"preview-session","subtype":"status","status":"compacting","content":\(json(message))}
    """
}

private func resultEvent(turnNumber: Int) -> String {
    """
    {"type":"result","session_id":"preview-session","usage":{"input_tokens":\(1_100 + turnNumber * 137),"output_tokens":\(180 + turnNumber * 23),"cache_read_input_tokens":\(640 + turnNumber * 89)},"conductor_sdk_metadata":{"model":"gpt-5","requestedFastMode":false}}
    """
}

private func json<Value: Encodable>(_ value: Value) -> String {
    String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
}
#endif
