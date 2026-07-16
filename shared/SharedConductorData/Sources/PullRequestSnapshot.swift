//
//  PullRequestSnapshot.swift
//  SharedConductorData
//
//  Created by Gannon Prudomme on 7/16/26.
//

/// The subset of Conductor's cached GitHub pull request state used by the mobile app.
public struct PullRequestSnapshot: Codable, Equatable, Sendable {
    public var url: String
    public var isDraft: Bool
    public var isMerged: Bool
    public var mergeStateStatus: String?
    public var checksStatus: String?

    public init(
        url: String,
        isDraft: Bool,
        isMerged: Bool,
        mergeStateStatus: String? = nil,
        checksStatus: String? = nil
    ) {
        self.url = url
        self.isDraft = isDraft
        self.isMerged = isMerged
        self.mergeStateStatus = mergeStateStatus
        self.checksStatus = checksStatus
    }

    private enum CodingKeys: String, CodingKey {
        case checksStatus = "checks_status"
        case isDraft = "is_draft"
        case isMerged = "is_merged"
        case mergeStateStatus = "merge_state_status"
        case url
    }
}
