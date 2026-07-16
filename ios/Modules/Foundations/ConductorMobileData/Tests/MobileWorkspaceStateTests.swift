//
//  MobileWorkspaceStateTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/16/26.
//

import SharedConductorData
import Testing

@testable import ConductorMobileData

struct MobileWorkspaceStateTests {
    @Test(
        "Pull request presentation follows Conductor's precedence",
        arguments: [
            (
                PullRequestSnapshot(
                    url: "https://github.com/example/repository/pull/1",
                    isDraft: true,
                    isMerged: false,
                    mergeStateStatus: "BLOCKED",
                    checksStatus: "failing"
                ),
                MobileWorkspaceState.PullRequestStatus.draft
            ),
            (
                PullRequestSnapshot(
                    url: "https://github.com/example/repository/pull/1",
                    isDraft: false,
                    isMerged: true
                ),
                .merged
            ),
            (
                PullRequestSnapshot(
                    url: "https://github.com/example/repository/pull/1",
                    isDraft: false,
                    isMerged: false,
                    mergeStateStatus: "DIRTY",
                    checksStatus: "failing"
                ),
                .mergeConflict
            ),
            (
                PullRequestSnapshot(
                    url: "https://github.com/example/repository/pull/1",
                    isDraft: false,
                    isMerged: false,
                    mergeStateStatus: "BLOCKED",
                    checksStatus: "failing"
                ),
                .failingChecks
            ),
            (
                PullRequestSnapshot(
                    url: "https://github.com/example/repository/pull/1",
                    isDraft: false,
                    isMerged: false,
                    mergeStateStatus: "UNSTABLE",
                    checksStatus: "failing"
                ),
                .readyToMerge
            ),
            (
                PullRequestSnapshot(
                    url: "https://github.com/example/repository/pull/1",
                    isDraft: false,
                    isMerged: false,
                    mergeStateStatus: "CLEAN",
                    checksStatus: "passing"
                ),
                .readyToMerge
            ),
        ]
    )
    func pullRequestStatus(
        pullRequest: PullRequestSnapshot,
        expectedStatus: MobileWorkspaceState.PullRequestStatus
    ) {
        let state = MobileWorkspaceState(
            workspaceID: "workspace",
            isWorking: false,
            pullRequest: pullRequest
        )

        #expect(state.pullRequestStatus == expectedStatus)
    }

    @Test("A workspace without a pull request has no pull request status")
    func noPullRequest() {
        let state = MobileWorkspaceState(workspaceID: "workspace", isWorking: false)

        #expect(state.pullRequestStatus == nil)
    }
}
