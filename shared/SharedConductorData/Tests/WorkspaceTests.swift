//
//  WorkspaceTests.swift
//  SharedConductorDataTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import Foundation
import SQLiteData
import Testing

struct WorkspaceTests {
    @Test("Workspace statuses preserve known and unknown values")
    func status() {
        #expect(Workspace.Status.done.rawValue == "done")
        #expect(Workspace.Status(rawValue: "waiting-on-user").rawValue == "waiting-on-user")
    }

    @Test("Workspace decodes a Conductor database record")
    func decoding() throws {
        let workspace = try JSONDecoder.conductor.decode(
            Workspace.self,
            from: Data(
                """
                {
                  "id": "workspace-1",
                  "created_at": "2026-07-09 00:00:00",
                  "updated_at": "2026-07-09 00:00:00",
                  "state": "ready"
                }
                """.utf8
            )
        )

        #expect(workspace.id == "workspace-1")
        #expect(workspace.state == .ready)
    }

    @Test("Workspace state decoding preserves unknown values")
    func unknownStateDecoding() throws {
        let workspace = try JSONDecoder.conductor.decode(
            Workspace.self,
            from: Data(
                """
                {
                  "id": "workspace-1",
                  "created_at": "2026-07-09 00:00:00",
                  "updated_at": "2026-07-09 00:00:00",
                  "state": "waiting_on_moonlight"
                }
                """.utf8
            )
        )

        #expect(workspace.state?.rawValue == "waiting_on_moonlight")
    }

    @Test("Workspace SQLite decoding parses ISO-8601 dates")
    func sqliteDateDecoding() throws {
        let database = try DatabaseQueue()
        try database.write { db in
            try db.execute(
                sql: """
                    CREATE TABLE workspaces (
                      created_at TEXT NOT NULL,
                      updated_at TEXT NOT NULL
                    );
                    INSERT INTO workspaces (created_at, updated_at)
                    VALUES ('2026-07-09T00:00:01.125Z', '2026-07-09T00:00:02Z');
                    """
            )
        }

        let dates = try #require(
            database.read { db in
                try Workspace
                    .select { ($0.createdAt, $0.updatedAt) }
                    .fetchOne(db)
            }
        )

        #expect(dates.0 == Date(timeIntervalSince1970: 1_783_555_201.125))
        #expect(dates.1 == Date(timeIntervalSince1970: 1_783_555_202))
    }
}
