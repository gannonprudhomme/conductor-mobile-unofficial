//
//  WorkspaceListSnapshotTests.swift
//  SharedConductorDataTests
//
//  Created by Gannon Prudomme on 7/13/26.
//

import Foundation
import SharedConductorData
import Testing

struct WorkspaceListSnapshotTests {
    @Test("Workspace list snapshots decode repositories, workspaces, and pull requests together")
    func decoding() throws {
        let snapshot = try JSONDecoder.conductor.decode(
            WorkspaceListSnapshot.self,
            from: Data(
                """
                {
                  "repositories": [
                    {
                      "id": "repository-1",
                      "created_at": "2026-07-09 00:00:00",
                      "updated_at": "2026-07-09 00:00:00"
                    }
                  ],
                  "workspaces": [
                    {
                      "id": "workspace-1",
                      "repository_id": "repository-1",
                      "created_at": "2026-07-09 00:00:00",
                      "updated_at": "2026-07-09 00:00:00",
                      "is_working": true
                    }
                  ],
                  "pull_requests": {
                    "workspace-1": {
                      "url": "https://github.com/example/repository/pull/42",
                      "is_draft": false,
                      "is_merged": false,
                      "merge_state_status": "CLEAN",
                      "checks_status": "passing"
                    }
                  }
                }
                """.utf8
            )
        )

        #expect(snapshot.repositories.map(\.id) == ["repository-1"])
        #expect(snapshot.workspaces.map(\.workspace.id) == ["workspace-1"])
        #expect(snapshot.workspaces.first?.isWorking == true)
        #expect(
            snapshot.pullRequests["workspace-1"]
                == PullRequestSnapshot(
                    url: "https://github.com/example/repository/pull/42",
                    isDraft: false,
                    isMerged: false,
                    mergeStateStatus: "CLEAN",
                    checksStatus: "passing"
                )
        )
    }

    @Test("Workspace list snapshots remain compatible with responses without pull requests")
    func decodingWithoutPullRequests() throws {
        let snapshot = try JSONDecoder.conductor.decode(
            WorkspaceListSnapshot.self,
            from: Data(
                """
                {
                  "repositories": [],
                  "workspaces": []
                }
                """.utf8
            )
        )

        #expect(snapshot.pullRequests.isEmpty)
    }
}
