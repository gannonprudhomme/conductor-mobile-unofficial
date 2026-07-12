//
//  WorkspaceDisplayTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
@testable import ConductorMobileData
import Foundation
import IssueReporting
import Testing

struct WorkspaceDisplayTests {
    @Test("Workspace status titles preserve unknown values")
    func statusTitles() {
        #expect(Workspace.Status.done.title == "Done")
        #expect(Workspace.Status(rawValue: "waiting-on-user").title == "waiting-on-user")
    }

    @Test("Workspace status prefers manual status, then derived status")
    func statusResolution() {
        let workspaces = [
            workspace(derivedStatus: "in-progress", manualStatus: "done"),
            workspace(derivedStatus: "in-review", manualStatus: nil),
            workspace(derivedStatus: "backlog", manualStatus: ""),
            workspace(derivedStatus: "in-progress", manualStatus: "waiting-on-user"),
        ]

        #expect(
            workspaces.map(\.status)
                == [.done, .inReview, .backlog, Workspace.Status(rawValue: "waiting-on-user")]
        )
    }

    @Test("Workspace status reports missing source data and falls back to in progress")
    func missingStatusReportsIssue() {
        withExpectedIssue {
            #expect(workspace(derivedStatus: nil, manualStatus: nil).status == .inProgress)
        }
    }

    @Test("Workspace display branch names use Conductor sentence case")
    func displayBranchNameFormatsConductorNames() {
        let workspace = Workspace.preview(branch: "foo-baz_qux")

        #expect(workspace.displayBranchName == "Foo baz qux")
    }

    @Test("Workspace display branch names use the first available name")
    func displayBranchNameFallsBackThroughAvailableNames() {
        let workspace = Workspace.preview(
            directoryName: "also-unused",
            placeholderBranchName: "stuttgart-v1",
            workspaceName: "unused-name"
        )

        #expect(workspace.displayBranchName == "Stuttgart v1")
    }
}

private func workspace(derivedStatus: String?, manualStatus: String?) -> Workspace {
    Workspace(
        id: "workspace-1",
        createdAt: Date(timeIntervalSince1970: 0),
        derivedStatus: derivedStatus,
        manualStatus: manualStatus,
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}
