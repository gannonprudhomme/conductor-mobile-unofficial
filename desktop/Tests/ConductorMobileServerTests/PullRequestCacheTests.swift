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

        let snapshots = PullRequestCache.readConductorPRCacheJSON(
            for: ["workspace", "missing"],
            at: directoryURL
        )

        #expect(snapshots.count == 1)
        #expect(snapshots["workspace"]?.url == "https://github.com/example/repository/pull/42")
        #expect(snapshots["workspace"]?.isDraft == true)
        #expect(snapshots["workspace"]?.isMerged == false)
        #expect(snapshots["workspace"]?.mergeStateStatus == .unstable)
        #expect(snapshots["workspace"]?.checksStatus == .failing)
    }

    @Test("Missing, malformed, incomplete, and invalid PR cache entries are ignored")
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
        try Data(
            #"{"prInfo":{"prUrl":"https://github.com/example/repository/pull/42"}}"#.utf8
        )
        .write(to: directoryURL.appending(path: "incomplete.json"))
        try Data(
            #"{"prInfo":{"prUrl":"not-a-url","isDraft":false,"isMerged":false}}"#.utf8
        )
        .write(to: directoryURL.appending(path: "invalid-url.json"))

        let snapshots = PullRequestCache.readConductorPRCacheJSON(
            for: ["missing", "malformed", "empty", "incomplete", "invalid-url"],
            at: directoryURL
        )

        #expect(snapshots.isEmpty)
    }
}
