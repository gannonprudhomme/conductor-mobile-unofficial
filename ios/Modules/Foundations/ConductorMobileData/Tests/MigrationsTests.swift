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
        let cloudPendingMutations = try database.read { db in
            try CloudPendingMutation.fetchCount(db)
        }
        let cloudMutationOutcomes = try database.read { db in
            try CloudMutationOutcome.fetchCount(db)
        }
        let cloudProjectMappings = try database.read { db in
            try CloudProjectRepositoryMapping.fetchCount(db)
        }
        let messageDeliveryAttempts = try database.read { db in
            try MessageDeliveryAttempt.fetchCount(db)
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
        #expect(cloudPendingMutations == 0)
        #expect(cloudMutationOutcomes == 0)
        #expect(cloudProjectMappings == 0)
        #expect(messageDeliveryAttempts == 0)
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
                == [
                    "workspace_id",
                    "account_id",
                    "last_seen_generation",
                    "remote_workspace_id",
                ]
        )
        #expect(
            Array(cloudSessionMetadataColumns.suffix(3)) == [
                "has_complete_transcript",
                "transcript_projection_version",
                "last_full_transcript_refresh_at",
            ]
        )
        #expect(cloudSessionMetadataDefaults.transcriptCursor == nil)
        #expect(!cloudSessionMetadataDefaults.hasCompleteTranscript)
        #expect(cloudSessionMetadataDefaults.transcriptProjectionVersion == 0)
        #expect(cloudSessionMetadataDefaults.lastFullTranscriptRefreshAt == nil)
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
        let workspace = Workspace.preview(id: "canonical-workspace")
        try database.write { db in
            try Workspace.insert { workspace }.execute(db)
            try db.execute(
                sql: """
                INSERT INTO "cloud_workspace_metadata" (
                  "workspace_id",
                  "account_id",
                  "last_seen_generation"
                ) VALUES (?, ?, ?)
                """,
                arguments: [
                    workspace.id,
                    "account",
                    "generation",
                ]
            )
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
        let workspaceMetadata = try database.read { db in
            try #require(
                try CloudWorkspaceMetadata.find(workspace.id).fetchOne(db)
            )
        }
        #expect(metadata.transcriptCursor == nil)
        #expect(!metadata.hasCompleteTranscript)
        #expect(metadata.transcriptProjectionVersion == 0)
        #expect(metadata.lastFullTranscriptRefreshAt == nil)
        #expect(workspaceMetadata.remoteWorkspaceID == workspace.id)
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

    @Test("Legacy Cloud sends migrate into the unified outbox")
    func legacyCloudSendMigration() throws {
        let database = try SQLiteData.defaultDatabase()
        let migrator = appDatabaseMigrator()
        try migrator.migrate(
            database,
            upTo: "Create initial prompt handoffs"
        )
        let legacyAttemptID = UUID(10)
        let messageID = UUID(11)
        let generation = UUID(12)
        let readyPromptMessageID = UUID(13)
        let linkedPromptMessageID = UUID(14)
        let missingSendAttemptID = UUID(15)
        let createdAt = Date(timeIntervalSince1970: 100)

        try database.write { database in
            try database.execute(
                sql: """
                INSERT INTO "cloud_pending_mutations" (
                  "attempt_id",
                  "account_id",
                  "credential_generation",
                  "operation",
                  "resource_kind",
                  "request_version",
                  "request_payload",
                  "rollback_payload",
                  "canonical_workspace_id",
                  "remote_workspace_id",
                  "canonical_session_id",
                  "remote_session_id",
                  "stable_remote_message_id",
                  "state",
                  "created_at",
                  "last_transition_at"
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    legacyAttemptID.uuidString.lowercased(),
                    "account",
                    generation.uuidString.lowercased(),
                    "send-message",
                    "message",
                    1,
                    Data(#"{"messageId":"legacy","message":"Implement it"}"#.utf8),
                    Data(#"{"submittedDraft":"  Implement it  "}"#.utf8),
                    "workspace",
                    "remote-workspace",
                    "session",
                    "remote-session",
                    messageID.uuidString.lowercased(),
                    "submitting",
                    createdAt,
                    createdAt,
                ]
            )
            try database.execute(
                sql: """
                INSERT INTO "initial_prompt_handoffs" (
                  "handoff_id",
                  "creation_attempt_id",
                  "account_id",
                  "credential_generation",
                  "canonical_workspace_id",
                  "remote_workspace_id",
                  "canonical_session_id",
                  "remote_session_id",
                  "original_prompt",
                  "stable_remote_message_id",
                  "installed_draft_text",
                  "state",
                  "created_at",
                  "last_transition_at"
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    UUID(16).uuidString.lowercased(),
                    UUID(17).uuidString.lowercased(),
                    "account",
                    generation.uuidString.lowercased(),
                    "ready-workspace",
                    "ready-remote-workspace",
                    "ready-session",
                    "ready-remote-session",
                    "Ready prompt",
                    readyPromptMessageID.uuidString.lowercased(),
                    "Ready prompt",
                    "ready",
                    createdAt,
                    createdAt,
                ]
            )
            try database.execute(
                sql: """
                INSERT INTO "initial_prompt_handoffs" (
                  "handoff_id",
                  "creation_attempt_id",
                  "account_id",
                  "credential_generation",
                  "canonical_workspace_id",
                  "remote_workspace_id",
                  "canonical_session_id",
                  "remote_session_id",
                  "original_prompt",
                  "stable_remote_message_id",
                  "send_attempt_id",
                  "installed_draft_text",
                  "state",
                  "created_at",
                  "last_transition_at"
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    UUID(18).uuidString.lowercased(),
                    UUID(19).uuidString.lowercased(),
                    "account",
                    generation.uuidString.lowercased(),
                    "linked-workspace",
                    "linked-remote-workspace",
                    "linked-session",
                    "linked-remote-session",
                    "Linked prompt",
                    linkedPromptMessageID.uuidString.lowercased(),
                    missingSendAttemptID.uuidString.lowercased(),
                    "Linked prompt",
                    "linked",
                    createdAt,
                    createdAt,
                ]
            )
            try database.execute(
                sql: """
                INSERT INTO "cloud_mutation_outcomes" (
                  "outcome_id",
                  "attempt_id",
                  "account_id",
                  "credential_generation",
                  "owning_feature",
                  "kind",
                  "version",
                  "payload",
                  "created_at"
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    UUID(20).uuidString.lowercased(),
                    missingSendAttemptID.uuidString.lowercased(),
                    "account",
                    generation.uuidString.lowercased(),
                    "chat:linked-session",
                    "rejected-mutation",
                    1,
                    Data(#"{"message":"Rejected"}"#.utf8),
                    createdAt,
                ]
            )
        }

        try migrator.migrate(database)

        let migratedAttemptIDs = try database.read { database in
            try String.fetchAll(
                database,
                sql: """
                SELECT "attempt_id"
                FROM "message_delivery_attempts"
                ORDER BY "created_at"
                """
            )
        }
        #expect(
            migratedAttemptIDs
                == [
                    messageID,
                    readyPromptMessageID,
                    linkedPromptMessageID,
                ]
                .map { $0.uuidString.lowercased() }
        )
        let attempt = try database.read { database in
            try #require(
                try MessageDeliveryAttempt.find(messageID)
                    .fetchOne(database)
            )
        }
        let pendingMutationCount = try database.read { database in
            try CloudPendingMutation.fetchCount(database)
        }
        let readyPrompt = try database.read { database in
            try #require(
                try MessageDeliveryAttempt.find(readyPromptMessageID)
                    .fetchOne(database)
            )
        }
        let linkedPrompt = try database.read { database in
            try #require(
                try MessageDeliveryAttempt.find(linkedPromptMessageID)
                    .fetchOne(database)
            )
        }
        let mutationOutcomeCount = try database.read { database in
            try CloudMutationOutcome.fetchCount(database)
        }
        let handoffTableCount = try database.read { database in
            try Int.fetchOne(
                database,
                sql: """
                SELECT COUNT(*)
                FROM sqlite_master
                WHERE type = 'table'
                  AND name = 'initial_prompt_handoffs'
                """
            )
        }

        #expect(attempt.deliveryRoute == .cloud)
        #expect(attempt.deliveryState == .ready)
        #expect(attempt.accountID == "account")
        #expect(attempt.credentialGeneration == generation)
        #expect(attempt.canonicalWorkspaceID == "workspace")
        #expect(attempt.remoteWorkspaceID == "remote-workspace")
        #expect(attempt.canonicalSessionID == "session")
        #expect(attempt.remoteSessionID == "remote-session")
        #expect(attempt.content == "Implement it")
        #expect(attempt.submittedDraft == "  Implement it  ")
        #expect(readyPrompt.deliveryState == .ready)
        #expect(readyPrompt.content == "Ready prompt")
        #expect(linkedPrompt.deliveryState == .rejected)
        #expect(
            linkedPrompt.resultDetail
                == "Cloud rejected this message before migration."
        )
        #expect(pendingMutationCount == 0)
        #expect(mutationOutcomeCount == 0)
        #expect(handoffTableCount == 0)
    }

    @Test("Legacy Cloud send states preserve no-repost recovery semantics")
    func legacyCloudSendStateMigration() throws {
        let database = try SQLiteData.defaultDatabase()
        let migrator = appDatabaseMigrator()
        try migrator.migrate(
            database,
            upTo: "Create initial prompt handoffs"
        )
        let generation = UUID(21)
        let readyMessageID = UUID(22)
        let startedMessageID = UUID(23)
        let indeterminateMessageID = UUID(24)
        let acceptedMessageID = UUID(25)
        let acknowledgedMessageID = UUID(26)
        let createdAt = Date(timeIntervalSince1970: 100)
        let legacySends: [
            (
                attemptID: UUID,
                messageID: UUID,
                state: String,
                dispatchStartedAt: Date?
            )
        ] = [
            (UUID(27), readyMessageID, "submitting", nil),
            (
                UUID(28),
                startedMessageID,
                "submitting",
                Date(timeIntervalSince1970: 101)
            ),
            (
                UUID(29),
                indeterminateMessageID,
                "indeterminate",
                Date(timeIntervalSince1970: 102)
            ),
            (UUID(30), acceptedMessageID, "accepted", nil),
            (UUID(31), acknowledgedMessageID, "acknowledged", nil),
        ]

        try database.write { database in
            for send in legacySends {
                try database.execute(
                    sql: """
                    INSERT INTO "cloud_pending_mutations" (
                      "attempt_id",
                      "account_id",
                      "credential_generation",
                      "operation",
                      "resource_kind",
                      "request_version",
                      "request_payload",
                      "canonical_workspace_id",
                      "remote_workspace_id",
                      "canonical_session_id",
                      "remote_session_id",
                      "stable_remote_message_id",
                      "state",
                      "dispatch_started_at",
                      "created_at",
                      "last_transition_at"
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        send.attemptID.uuidString.lowercased(),
                        "account",
                        generation.uuidString.lowercased(),
                        "send-message",
                        "message",
                        1,
                        Data(
                            #"{"messageId":"legacy","message":"Implement it"}"#
                                .utf8
                        ),
                        "workspace",
                        "remote-workspace",
                        "session",
                        "remote-session",
                        send.messageID.uuidString.lowercased(),
                        send.state,
                        send.dispatchStartedAt,
                        createdAt,
                        createdAt,
                    ]
                )
            }
        }

        try migrator.migrate(database)

        let attempts = try database.read { database in
            try MessageDeliveryAttempt.all.fetchAll(database)
        }
        let states = Dictionary(
            uniqueKeysWithValues: attempts.map {
                ($0.attemptID, $0.deliveryState)
            }
        )
        #expect(states[readyMessageID] == .ready)
        #expect(states[startedMessageID] == .unknown)
        #expect(states[indeterminateMessageID] == .unknown)
        #expect(states[acceptedMessageID] == .accepted)
        #expect(states[acknowledgedMessageID] == nil)
        #expect(attempts.count == 4)
        #expect(
            try database.read { database in
                try CloudPendingMutation.fetchCount(database)
            } == 0
        )
    }
}
