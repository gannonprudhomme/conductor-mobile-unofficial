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
