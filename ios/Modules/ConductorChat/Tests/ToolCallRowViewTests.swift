//
//  ToolCallRowViewTests.swift
//  ConductorChatTests
//
//  Created by Gannon Prudomme on 7/27/26.
//

@testable import ConductorChat
import Testing

@Suite("Tool call row view")
struct ToolCallRowViewTests {
    @Test("Shell command display removes transport wrappers")
    func shellCommandTransportWrappers() {
        let fixtures = [
            (
                #"/bin/bash -lc "git diff --check && git status --short""#,
                "git diff --check && git status --short"
            ),
            (
                #"/bin/bash -lc 'git add ios/Modules/ConductorChat'"#,
                "git add ios/Modules/ConductorChat"
            ),
            (
                #"bash -lc "mise -C ios run test""#,
                "mise -C ios run test"
            ),
            (
                #"/bin/zsh -lc 'xcodebuild test -scheme ConductorChat'"#,
                "xcodebuild test -scheme ConductorChat"
            ),
            (
                #"/bin/sh -c 'git status --short'"#,
                "git status --short"
            ),
        ]

        for (command, expected) in fixtures {
            #expect(shellCommandForDisplay(command) == expected)
        }
    }

    @Test("Shell command display preserves meaningful or incomplete wrappers")
    func meaningfulShellCommands() {
        let commands = [
            "git diff --check",
            "cd ios && mise run test",
            "env NSUnbufferedIO=YES xcodebuild test",
            #"/bin/bash -lc "git status --short'"#,
            #"/bin/bash -lc git status --short"#,
        ]

        for command in commands {
            #expect(shellCommandForDisplay(command) == command)
        }
    }

    @Test("Edit line changes count inserted and removed lines")
    @MainActor
    func editLineChanges() {
        let stats = LinesChangesStats(
            oldString: """
                unchanged
                remove one
                remove two
                """,
            newString: """
                unchanged
                add one
                add two
                add three
                """
        )

        #expect(stats.additions == 3)
        #expect(stats.deletions == 2)
    }

    @Test("Edit line changes include zero additions")
    @MainActor
    func editLineRemovals() {
        let oldString = (1...26)
            .map { "line \($0)" }
            .joined(separator: "\n") + "\n"
        let stats = LinesChangesStats(oldString: oldString, newString: "")

        #expect(stats.additions == 0)
        #expect(stats.deletions == 26)
    }
}
