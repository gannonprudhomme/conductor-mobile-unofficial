//
//  MigrationsTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
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
        let cloudMessageMetadataColumns = try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('cloud_message_metadata')"
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
            cloudSessionMetadataColumns
                == [
                    "session_id",
                    "workspace_id",
                    "account_id",
                    "last_seen_generation",
                ]
        )
        #expect(
            cloudMessageMetadataColumns
                == [
                    "message_id",
                    "session_id",
                    "account_id",
                    "source_message_id",
                    "last_seen_generation",
                ]
        )
    }
}
