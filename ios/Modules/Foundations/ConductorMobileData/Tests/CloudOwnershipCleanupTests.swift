//
//  CloudOwnershipCleanupTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/28/26.
//

import ConductorCloud
import Foundation
import SharedConductorData
import SQLiteData
@testable import ConductorMobileData
import Testing

struct CloudOwnershipCleanupTests {
    @Test("Authoritative cleanup preserves an acknowledged send subtree")
    func acknowledgedSendProtectsSubtree() throws {
        let database = try appDatabase()
        let fixture = try insertFixture(in: database)
        let attempt = try CloudPendingMutation(
            accountID: fixture.accountID,
            credentialGeneration: UUID(1),
            operation: .sendMessage,
            resourceKind: .message,
            request: CloudSendMessageRequest(
                messageID: "remote-message",
                message: "Hello"
            ),
            canonicalWorkspaceID: fixture.workspaceID,
            remoteWorkspaceID: "remote-workspace",
            canonicalSessionID: fixture.sessionID,
            remoteSessionID: "remote-session",
            stableRemoteMessageID: "remote-message",
            state: .acknowledged
        )
        try database.write { database in
            try CloudPendingMutation.insert { attempt }.execute(database)
            try CloudOwnershipCleanup.perform(
                scope: .workspaces([fixture.workspaceID]),
                reason: .authoritativeSnapshot,
                in: database
            )
        }

        try database.read { database in
            let workspace = try Workspace.find(fixture.workspaceID)
                .fetchOne(database)
            let session = try Session.find(fixture.sessionID)
                .fetchOne(database)
            let persistedAttempt = try CloudPendingMutation
                .find(attempt.attemptID)
                .fetchOne(database)
            #expect(workspace != nil)
            #expect(session != nil)
            #expect(persistedAttempt != nil)
        }
    }

    @Test("Credential removal ignores protections and removes the subtree")
    func credentialRemovalIgnoresProtections() throws {
        let database = try appDatabase()
        let fixture = try insertFixture(in: database)
        let handoff = InitialPromptHandoff(
            creationAttemptID: UUID(2),
            accountID: fixture.accountID,
            credentialGeneration: UUID(3),
            canonicalWorkspaceID: fixture.workspaceID,
            remoteWorkspaceID: "remote-workspace",
            canonicalSessionID: fixture.sessionID,
            remoteSessionID: "remote-session",
            originalPrompt: "Hello"
        )
        try database.write { database in
            try InitialPromptHandoff.insert { handoff }.execute(database)
            try CloudOwnershipCleanup.perform(
                scope: .account(fixture.accountID),
                reason: .credentialRemoval,
                in: database
            )
        }

        try database.read { database in
            let workspace = try Workspace.find(fixture.workspaceID)
                .fetchOne(database)
            let session = try Session.find(fixture.sessionID)
                .fetchOne(database)
            let persistedHandoff = try InitialPromptHandoff
                .find(handoff.handoffID)
                .fetchOne(database)
            let workspaceMetadata = try CloudWorkspaceMetadata
                .find(fixture.workspaceID)
                .fetchOne(database)
            #expect(workspace == nil)
            #expect(session == nil)
            #expect(persistedHandoff == nil)
            #expect(workspaceMetadata == nil)
        }
    }
}

private func insertFixture(
    in database: any DatabaseWriter
) throws -> (
    accountID: String,
    workspaceID: Workspace.ID,
    sessionID: Session.ID
) {
    let accountID = "account"
    let repository = Repository.preview(id: "repository")
    let workspace = Workspace.preview(
        id: "workspace",
        repositoryID: repository.id
    )
    let session = Session.preview(
        id: "session",
        workspaceID: workspace.id
    )
    try database.write { database in
        try Repository.insert { repository }.execute(database)
        try Workspace.insert { workspace }.execute(database)
        try CloudWorkspaceMetadata
            .insert {
                CloudWorkspaceMetadata(
                    workspaceID: workspace.id,
                    accountID: accountID,
                    remoteWorkspaceID: "remote-workspace",
                    lastSeenGeneration: "generation"
                )
            }
            .execute(database)
        try Session.insert { session }.execute(database)
        try CloudSessionMetadata
            .insert {
                CloudSessionMetadata(
                    canonicalSessionID: session.id,
                    cloudSessionID: "remote-session",
                    workspaceID: workspace.id,
                    accountID: accountID,
                    listOrder: 0,
                    refreshGeneration: "generation"
                )
            }
            .execute(database)
    }
    return (accountID, workspace.id, session.id)
}
