//
//  WorkspaceSnapshot+QueryTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/27/26.
//

import SharedConductorData
import SQLiteData
import Testing

@testable import ConductorMobileServer

struct WorkspaceSnapshotQueryTests {
    @Test("Workspace snapshots accept cloud-synchronized timestamps")
    func cloudTimestamps() throws {
        let database = try testConductorDatabase()
        try database.write { database in
            try database.execute(
                sql: """
                    INSERT INTO workspaces (id, created_at, updated_at)
                    VALUES (
                      'cloud-workspace',
                      '2026-07-27 04:19:08.237879+00',
                      '2026-07-27 04:19:09.123456+00'
                    )
                    """
            )
        }

        let snapshots = try database.read { database in
            try WorkspaceSnapshot.mostRecentlyUpdated.fetchAll(database)
        }

        #expect(snapshots.map(\.workspace.id) == ["cloud-workspace"])
    }
}
