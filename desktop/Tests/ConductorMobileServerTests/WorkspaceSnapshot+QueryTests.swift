//
//  WorkspaceSnapshot+QueryTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/27/26.
//

import Foundation
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

    @Test("Workspace snapshots are not limited to 200 rows")
    func moreThanTwoHundredWorkspaces() throws {
        let database = try testConductorDatabase()
        let date = Date(timeIntervalSince1970: 1_783_555_200)
        let workspaces = (0...200).map { index in
            Workspace(
                id: "workspace-\(index)",
                createdAt: date.addingTimeInterval(TimeInterval(index)),
                state: index == 200 ? .archived : .ready,
                updatedAt: date.addingTimeInterval(TimeInterval(index))
            )
        }

        try database.write { database in
            try Workspace
                .insert { workspaces }
                .execute(database)
        }

        let snapshots = try database.read { database in
            try WorkspaceSnapshot.mostRecentlyUpdated.fetchAll(database)
        }

        #expect(snapshots.count == workspaces.count)
        #expect(snapshots.first?.workspace.id == "workspace-200")
        #expect(snapshots.last?.workspace.id == "workspace-0")
    }
}
