//
//  PullRequestCacheTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/16/26.
//

import Foundation
import Testing

@testable import ConductorMobileServer

struct PullRequestCacheTests {
    @Test("Cached pull request state is normalized for mobile")
    func snapshot() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        try Data(
            """
            {
              "prInfo": {
                "prUrl": "https://github.com/example/repository/pull/42",
                "isDraft": true,
                "isMerged": false,
                "mergeStateStatus": "UNSTABLE",
                "checksStatus": "failing",
                "ignoredFutureValue": true
              },
              "repositoryId": "repository",
              "localBranch": "feature"
            }
            """.utf8
        )
        .write(to: directoryURL.appending(path: "workspace.json"))

        let snapshots = PullRequestCache.snapshots(
            for: ["workspace", "missing"],
            at: directoryURL
        )

        #expect(snapshots.count == 1)
        #expect(snapshots["workspace"]?.url == "https://github.com/example/repository/pull/42")
        #expect(snapshots["workspace"]?.isDraft == true)
        #expect(snapshots["workspace"]?.isMerged == false)
        #expect(snapshots["workspace"]?.mergeStateStatus == "UNSTABLE")
        #expect(snapshots["workspace"]?.checksStatus == "failing")
    }

    @Test("Missing, malformed, and empty PR cache entries are ignored")
    func invalidEntries() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        try Data("not json".utf8)
            .write(to: directoryURL.appending(path: "malformed.json"))
        try Data(#"{"prInfo":{}}"#.utf8)
            .write(to: directoryURL.appending(path: "empty.json"))

        let snapshots = PullRequestCache.snapshots(
            for: ["missing", "malformed", "empty"],
            at: directoryURL
        )

        #expect(snapshots.isEmpty)
    }
}
