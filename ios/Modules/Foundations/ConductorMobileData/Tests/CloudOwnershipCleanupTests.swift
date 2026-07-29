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
    @Test("Removing Cloud ownership restores the raw Desktop workspace ID")
    func cloudRemovalRestoresDesktopWorkspaceID() throws {
        let database = try appDatabase()
        let fixture = try insertFixture(in: database)
        let desktopSession = Session.preview(
            id: "desktop-session",
            workspaceID: fixture.workspaceID
        )
        let desktopAttempt = MessageDeliveryAttempt(
            attemptID: UUID(4),
            route: .desktop,
            desktopEndpoint: "http://desktop.test",
            canonicalWorkspaceID: fixture.workspaceID,
            remoteWorkspaceID: "remote-workspace",
            canonicalSessionID: desktopSession.id,
            remoteSessionID: desktopSession.id,
            content: "Hello",
            model: .gpt5_5,
            isFastModeEnabled: false,
            mode: .sent,
            reasoningEffort: .high,
            submittedDraft: "Hello"
        )
        try database.write { database in
            try MobileWorkspaceState.insert {
                MobileWorkspaceState(
                    workspaceID: fixture.workspaceID,
                    isWorking: true
                )
            }
            .execute(database)
            try Session.insert { desktopSession }.execute(database)
            try MessageDeliveryAttempt.insert { desktopAttempt }
                .execute(database)

            try CloudOwnershipCleanup.perform(
                scope: .workspaces([fixture.workspaceID]),
                reason: .authoritativeSnapshot,
                in: database
            )
        }

        let persisted = try database.read { database in
            (
                canonicalWorkspace: try Workspace
                    .find(fixture.workspaceID)
                    .fetchOne(database),
                desktopWorkspace: try Workspace
                    .find("remote-workspace")
                    .fetchOne(database),
                mobileState: try MobileWorkspaceState
                    .find("remote-workspace")
                    .fetchOne(database),
                desktopSession: try Session
                    .find(desktopSession.id)
                    .fetchOne(database),
                desktopAttempt: try MessageDeliveryAttempt
                    .find(desktopAttempt.attemptID)
                    .fetchOne(database)
            )
        }
        #expect(persisted.canonicalWorkspace == nil)
        #expect(persisted.desktopWorkspace?.id == "remote-workspace")
        #expect(persisted.desktopWorkspace?.hostingServerURL == nil)
        #expect(persisted.mobileState?.isWorking == true)
        #expect(persisted.desktopSession?.workspaceID == "remote-workspace")
        #expect(
            persisted.desktopAttempt?.canonicalWorkspaceID
                == "remote-workspace"
        )
    }

    @Test("Authoritative cleanup preserves an unresolved delivery subtree")
    func unresolvedDeliveryProtectsSubtree() throws {
        let database = try appDatabase()
        let fixture = try insertFixture(in: database)
        let attempt = MessageDeliveryAttempt(
            attemptID: UUID(0),
            route: .cloud,
            accountID: fixture.accountID,
            credentialGeneration: UUID(1),
            canonicalWorkspaceID: fixture.workspaceID,
            remoteWorkspaceID: "remote-workspace",
            canonicalSessionID: fixture.sessionID,
            remoteSessionID: "remote-session",
            content: "Hello",
            model: Session.Model(rawValue: "sonnet-4-6"),
            isFastModeEnabled: false,
            mode: .sent,
            reasoningEffort: .high,
            submittedDraft: "Hello",
            state: .unknown
        )
        try database.write { database in
            try MessageDeliveryAttempt.insert { attempt }.execute(database)
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
            let persistedAttempt = try MessageDeliveryAttempt
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
        let attempt = MessageDeliveryAttempt(
            attemptID: UUID(2),
            route: .cloud,
            accountID: fixture.accountID,
            credentialGeneration: UUID(3),
            canonicalWorkspaceID: fixture.workspaceID,
            remoteWorkspaceID: "remote-workspace",
            canonicalSessionID: fixture.sessionID,
            remoteSessionID: "remote-session",
            content: "Hello",
            model: Session.Model(rawValue: "sonnet-4-6"),
            isFastModeEnabled: false,
            mode: .sent,
            reasoningEffort: .high,
            submittedDraft: "Hello"
        )
        try database.write { database in
            try MessageDeliveryAttempt.insert { attempt }.execute(database)
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
            let persistedAttempt = try MessageDeliveryAttempt
                .find(attempt.attemptID)
                .fetchOne(database)
            let workspaceMetadata = try CloudWorkspaceMetadata
                .find(fixture.workspaceID)
                .fetchOne(database)
            #expect(workspace == nil)
            #expect(session == nil)
            #expect(persistedAttempt == nil)
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
