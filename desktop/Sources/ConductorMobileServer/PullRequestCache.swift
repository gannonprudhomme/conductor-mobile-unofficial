//
//  PullRequestCache.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/16/26.
//

import Foundation
import SharedConductorData

enum PullRequestCache {
    static func readConductorPRCacheJSON(
        for workspaceIDs: [Workspace.ID],
        at directoryURL: URL?
    ) -> [Workspace.ID: PullRequestSnapshot] {
        guard let directoryURL else {
            return [:]
        }

        return workspaceIDs.reduce(into: [:]) { snapshots, workspaceID in
            let fileURL = directoryURL.appending(path: "\(workspaceID).json")
            guard let data = try? Data(contentsOf: fileURL),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  let snapshot = entry.pullRequest
            else {
                return
            }

            snapshots[workspaceID] = snapshot
        }
    }

    private struct Entry: Decodable {
        var prInfo: PullRequestInfo

        var pullRequest: PullRequestSnapshot? {
            guard let rawURL = prInfo.prURL,
                  let url = URL(string: rawURL),
                  url.scheme != nil,
                  url.host != nil,
                  let isDraft = prInfo.isDraft,
                  let isMerged = prInfo.isMerged
            else {
                return nil
            }

            return PullRequestSnapshot(
                url: url.absoluteString,
                isDraft: isDraft,
                isMerged: isMerged,
                mergeStateStatus: prInfo.mergeStateStatus,
                checksStatus: prInfo.checksStatus
            )
        }
    }

    private struct PullRequestInfo: Decodable {
        var checksStatus: PullRequestSnapshot.ChecksStatus?
        var isDraft: Bool?
        var isMerged: Bool?
        var mergeStateStatus: PullRequestSnapshot.MergeStateStatus?
        var prURL: String?

        private enum CodingKeys: String, CodingKey {
            case checksStatus
            case isDraft
            case isMerged
            case mergeStateStatus
            case prURL = "prUrl"
        }
    }
}
