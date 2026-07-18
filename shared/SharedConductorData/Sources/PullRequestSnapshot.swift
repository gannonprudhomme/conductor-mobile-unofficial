//
//  PullRequestSnapshot.swift
//  SharedConductorData
//
//  Created by Gannon Prudomme on 7/16/26.
//

import SQLiteData

/// The subset of Conductor's cached GitHub pull request state used by the mobile app.
public struct PullRequestSnapshot: Codable, Equatable, Sendable {
    public var url: String
    public var isDraft: Bool
    public var isMerged: Bool
    public var mergeStateStatus: MergeStateStatus?
    public var checksStatus: ChecksStatus?

    public init(
        url: String,
        isDraft: Bool,
        isMerged: Bool,
        mergeStateStatus: MergeStateStatus? = nil,
        checksStatus: ChecksStatus? = nil
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

    public struct ChecksStatus: Codable, Hashable, QueryBindable, QueryDecodable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let failing = Self(rawValue: "failing")
        public static let passing = Self(rawValue: "passing")
    }

    public struct MergeStateStatus: Codable, Hashable, QueryBindable, QueryDecodable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let blocked = Self(rawValue: "BLOCKED")
        public static let clean = Self(rawValue: "CLEAN")
        public static let dirty = Self(rawValue: "DIRTY")
        public static let unstable = Self(rawValue: "UNSTABLE")
    }
}
