//
//  MigrationsTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Foundation
import SharedConductorData
import SQLiteData
@testable import ConductorMobileData
import Testing

struct MigrationsTests {
    @Test("Migrations create readable tables")
    func createReadableTables() throws {
        let database = try appDatabase()

        let workspaces = try database.read { db in
            try Workspace.fetchCount(db)
        }
        let mobileWorkspaceStates = try database.read { db in
            try MobileWorkspaceState.fetchCount(db)
        }
        let cloudWorkspaceMetadata = try database.read { db in
            try CloudWorkspaceMetadata.fetchCount(db)
        }
        let cloudSessionMetadata = try database.read { db in
            try CloudSessionMetadata.fetchCount(db)
        }
        let cloudMessageMetadata = try database.read { db in
            try CloudMessageMetadata.fetchCount(db)
        }
        let sessions = try database.read { db in
            try Session.fetchCount(db)
        }
        let untitledSession = Session.preview(title: nil)
        try database.write { db in
            try Session.insert { untitledSession }.execute(db)
        }
        let persistedUntitledSession = try database.read { db in
            try Session.find(untitledSession.id).fetchOne(db)
        }
        let repositories = try database.read { db in
            try Repository.fetchCount(db)
        }
        let messages = try database.read { db in
            try Message.fetchCount(db)
        }
        let workspaceColumns = try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('workspaces')"
            )
        }
        let mobileWorkspaceStateColumns = try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('mobile_workspace_state')"
            )
        }
        let sessionColumns = try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('sessions')"
            )
        }
        let cloudWorkspaceMetadataColumns = try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('cloud_workspace_metadata')"
            )
        }
        let cloudSessionMetadataColumns = try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('cloud_session_metadata')"
            )
        }
        let cloudSessionMetadataDefaults = try database.write { db in
            let session = Session.preview(id: "cloud-session")
            try Session.insert { session }.execute(db)
            try CloudSessionMetadata
                .insert {
                    CloudSessionMetadata(
                        canonicalSessionID: session.id,
                        cloudSessionID: "remote-session",
                        workspaceID: session.workspaceID,
                        accountID: "account",
                        listOrder: 0,
                        refreshGeneration: "generation"
                    )
                }
                .execute(db)
            return try #require(
                try CloudSessionMetadata.find(session.id).fetchOne(db)
            )
        }
        let desktopTranscriptMetadataColumns = try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('desktop_transcript_metadata')"
            )
        }
        let desktopTranscriptTables = try database.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT name
                    FROM sqlite_master
                    WHERE type = 'table' AND name LIKE 'desktop_%'
                    ORDER BY name
                    """
            )
        }

        #expect(workspaces == 0)
        #expect(mobileWorkspaceStates == 0)
        #expect(cloudWorkspaceMetadata == 0)
        #expect(cloudSessionMetadata == 0)
        #expect(cloudMessageMetadata == 0)
        #expect(sessions == 0)
        #expect(persistedUntitledSession?.title == nil)
        #expect(repositories == 0)
        #expect(messages == 0)
        #expect(!workspaceColumns.contains("CUSTOM_is_working"))
        #expect(mobileWorkspaceStateColumns.contains("pull_request_url"))
        #expect(mobileWorkspaceStateColumns.contains("pull_request_is_draft"))
        #expect(mobileWorkspaceStateColumns.contains("pull_request_is_merged"))
        #expect(mobileWorkspaceStateColumns.contains("pull_request_merge_state_status"))
        #expect(mobileWorkspaceStateColumns.contains("pull_request_checks_status"))
        #expect(sessionColumns.contains("fast_mode"))
        #expect(sessionColumns.contains("queue_paused_at"))
        #expect(sessionColumns.contains("codex_thinking_level"))
        #expect(sessionColumns.contains("claude_effort_level"))
        #expect(
            cloudWorkspaceMetadataColumns
                == ["workspace_id", "account_id", "last_seen_generation"]
        )
        #expect(
            Array(cloudSessionMetadataColumns.suffix(3)) == [
                "transcript_cursor",
                "has_complete_transcript",
                "transcript_projection_version",
            ]
        )
        #expect(cloudSessionMetadataDefaults.transcriptCursor == nil)
        #expect(!cloudSessionMetadataDefaults.hasCompleteTranscript)
        #expect(cloudSessionMetadataDefaults.transcriptProjectionVersion == 0)
        #expect(
            desktopTranscriptMetadataColumns == [
                "session_id",
                "transcript_cursor",
            ]
        )
        #expect(desktopTranscriptTables == ["desktop_transcript_metadata"])
    }

    @Test("Checkpoint migration defaults existing Cloud session metadata")
    func checkpointMigrationDefaults() throws {
        let database = try SQLiteData.defaultDatabase()
        let migrator = appDatabaseMigrator()
        try migrator.migrate(
            database,
            upTo: "Create cloud chat metadata"
        )
        let session = Session.preview(id: "canonical-session")
        try database.write { db in
            try Session.insert { session }.execute(db)
            try db.execute(
                sql: """
                INSERT INTO "cloud_session_metadata" (
                  "canonical_session_id",
                  "cloud_session_id",
                  "workspace_id",
                  "account_id",
                  "list_order",
                  "refresh_generation"
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    session.id,
                    "remote-session",
                    session.workspaceID,
                    "account",
                    0,
                    "generation",
                ]
            )
        }

        try migrator.migrate(database)

        let metadata = try database.read { db in
            try #require(
                try CloudSessionMetadata.find(session.id).fetchOne(db)
            )
        }
        #expect(metadata.transcriptCursor == nil)
        #expect(!metadata.hasCompleteTranscript)
        #expect(metadata.transcriptProjectionVersion == 0)
    }

    @Test("A cursorless desktop transcript row represents a complete empty baseline")
    func desktopTranscriptMetadataDefaults() throws {
        let database = try appDatabase()
        let workspace = Workspace.preview()
        let session = Session.preview()
        let metadata = try database.write { database in
            try Workspace.insert { workspace }.execute(database)
            try Session.insert { session }.execute(database)
            try database.execute(
                sql: """
                    INSERT INTO desktop_transcript_metadata (session_id)
                    VALUES (?)
                    """,
                arguments: [session.id]
            )
            return try #require(
                try DesktopTranscriptMetadata.find(session.id).fetchOne(database)
            )
        }

        #expect(metadata.transcriptCursor == nil)
    }

    @Test("Desktop metadata migration preserves unrelated message rows")
    func desktopTranscriptMetadataPreservesMessages() throws {
        let database = try SQLiteData.defaultDatabase()
        let migrator = appDatabaseMigrator()
        try migrator.migrate(
            database,
            upTo: "Add cloud transcript checkpoint"
        )
        let orphan = Message(
            id: "orphan",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        try database.write { database in
            try Message.insert { orphan }.execute(database)
        }

        try migrator.migrate(database)

        #expect(
            try database.read { database in
                try Message.find(orphan.id).fetchOne(database)
            } == orphan
        )
    }

    @Test("Desktop transcript metadata enforces constraints and cascades")
    func desktopTranscriptMetadataConstraints() throws {
        let database = try appDatabase()
        let workspace = Workspace.preview()
        let session = Session.preview()
        try database.write { db in
            try Workspace.insert { workspace }.execute(db)
            try Session.insert { session }.execute(db)
            try db.execute(
                sql: """
                    INSERT INTO desktop_transcript_metadata (
                      session_id, transcript_cursor
                    ) VALUES (?, 'message-1')
                    """,
                arguments: [session.id]
            )
        }

        #expect(throws: (any Error).self) {
            try database.write { db in
                try db.execute(
                    sql: """
                        UPDATE desktop_transcript_metadata
                        SET transcript_cursor = ''
                        WHERE session_id = ?
                        """,
                    arguments: [session.id]
                )
            }
        }

        try database.write { db in
            try Session.find(session.id).delete().execute(db)
            try Workspace.find(workspace.id).delete().execute(db)
        }
        let count = try database.read { db in
            try DesktopTranscriptMetadata.fetchCount(db)
        }
        #expect(count == 0)
    }
}
