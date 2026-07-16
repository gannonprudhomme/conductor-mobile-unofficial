//
//  MobileWorkspaceState.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import SQLiteData

/// Mobile-only state associated with a row in Conductor's `workspaces` table.
@Table("mobile_workspace_state")
public struct MobileWorkspaceState: Equatable, Identifiable, Sendable {
    public enum PullRequestStatus: Equatable, Sendable {
        case draft
        case failingChecks
        case readyToMerge
        case mergeConflict
        case merged
    }

    /// The corresponding workspace ID. It remains stored in an `id` column so it is the table's
    /// primary key while making its relationship to `Workspace.id` explicit in Swift.
    @Column("id", primaryKey: true)
    public let workspaceID: Workspace.ID
    @Column("is_working")
    public var isWorking: Bool
    @Column("pull_request_url")
    public var pullRequestURL: String?
    @Column("pull_request_is_draft")
    public var isPullRequestDraft: Bool
    @Column("pull_request_is_merged")
    public var isPullRequestMerged: Bool
    @Column("pull_request_merge_state_status")
    public var pullRequestMergeStateStatus: String?
    @Column("pull_request_checks_status")
    public var pullRequestChecksStatus: String?

    public init(
        workspaceID: Workspace.ID,
        isWorking: Bool,
        pullRequest: PullRequestSnapshot? = nil
    ) {
        self.workspaceID = workspaceID
        self.isWorking = isWorking
        self.pullRequestURL = pullRequest?.url
        self.isPullRequestDraft = pullRequest?.isDraft ?? false
        self.isPullRequestMerged = pullRequest?.isMerged ?? false
        self.pullRequestMergeStateStatus = pullRequest?.mergeStateStatus
        self.pullRequestChecksStatus = pullRequest?.checksStatus
    }

    public var id: Workspace.ID { workspaceID }

    public var pullRequestStatus: PullRequestStatus? {
        guard pullRequestURL != nil else {
            return nil
        }

        if isPullRequestDraft {
            return .draft
        } else if isPullRequestMerged {
            return .merged
        } else if pullRequestMergeStateStatus == "DIRTY" {
            return .mergeConflict
        } else if pullRequestMergeStateStatus == "BLOCKED",
                  pullRequestChecksStatus == "failing" {
            // Conductor only shows its red CI state when a failing required check blocks merge.
            return .failingChecks
        } else {
            return .readyToMerge
        }
    }
}
