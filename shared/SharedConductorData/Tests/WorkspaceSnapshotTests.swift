//
//  WorkspaceSnapshotTests.swift
//  SharedConductorDataTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import Foundation
import Testing

struct WorkspaceSnapshotTests {
    @Test("Workspace snapshots decode desktop-derived activity")
    func decoding() throws {
        let snapshot = try JSONDecoder.conductor.decode(
            WorkspaceSnapshot.self,
            from: Data(
                """
                {
                  "id": "workspace-1",
                  "created_at": "2026-07-09 00:00:00",
                  "updated_at": "2026-07-09 00:00:00",
                  "is_working": true
                }
                """.utf8
            )
        )

        #expect(snapshot.workspace.id == "workspace-1")
        #expect(snapshot.isWorking)
    }
}
