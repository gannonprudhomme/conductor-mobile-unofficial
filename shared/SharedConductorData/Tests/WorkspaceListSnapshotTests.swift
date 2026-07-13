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
    @Test("Workspace list snapshots decode repositories and workspaces together")
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
                  ]
                }
                """.utf8
            )
        )

        #expect(snapshot.repositories.map(\.id) == ["repository-1"])
        #expect(snapshot.workspaces.map(\.workspace.id) == ["workspace-1"])
        #expect(snapshot.workspaces.first?.isWorking == true)
    }
}
