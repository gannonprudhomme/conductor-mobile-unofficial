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

    @Test("Empty chat directory names use the workspace, branch, directory, path, then ID")
    func emptyChatDirectoryName() {
        let workspaces = [
            Workspace.preview(
                id: "workspace-1",
                branch: "unused-branch",
                directoryName: "unused-directory",
                workspaceName: "preferred workspace  name",
                workspacePath: "/Users/test/path-directory"
            ),
            Workspace.preview(
                id: "workspace-2",
                branch: "preferred-branch",
                directoryName: "unused-directory",
                workspacePath: "/Users/test/nil-directory"
            ),
            Workspace.preview(
                id: "workspace-3",
                branch: "",
                directoryName: "preferred-directory",
                workspacePath: "/Users/test/empty-directory/"
            ),
            Workspace.preview(
                id: "workspace-4",
                branch: "",
                directoryName: "",
                workspacePath: "/Users/test/preferred-path/"
            ),
            Workspace.preview(
                id: "workspace-5",
                workspaceName: "",
                workspacePath: ""
            ),
        ]

        #expect(
            workspaces.map(\.emptyChatDirectoryName)
                == [
                    "preferred-workspace-name",
                    "preferred-branch",
                    "preferred-directory",
                    "preferred-path",
                    "workspace-5",
                ]
        )
    }

    @Test("Workspace display names prefer pull request titles")
    func displayNamePrefersPullRequestTitle() {
        let workspace = Workspace.preview(
            branch: "unused-branch",
            prTitle: "Preferred pull request title",
            workspaceName: "unused workspace name"
        )

        #expect(workspace.displayName == "Preferred pull request title")
    }

    @Test("Workspace display names preserve explicit names")
    func displayNamePreservesWorkspaceName() {
        let workspace = Workspace.preview(
            branch: "unused-branch",
            workspaceName: "renamed workspace name"
        )

        #expect(workspace.displayName == "renamed workspace name")
    }

    @Test("Workspace display names use Conductor sentence case for branches")
    func displayNameFormatsConductorBranches() {
        let workspace = Workspace.preview(branch: "foo-baz_qux")

        #expect(workspace.displayName == "Foo baz qux")
    }

    @Test("Workspace display names use the first available fallback")
    func displayNameFallsBackThroughAvailableNames() {
        let workspace = Workspace.preview(
            directoryName: "also-unused",
            placeholderBranchName: "stuttgart-v1"
        )

        #expect(workspace.displayName == "Stuttgart v1")
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
