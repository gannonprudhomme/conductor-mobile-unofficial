//
//  CloudContentPersistenceTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/27/26.
//

import ConductorCloud
@testable import ConductorMobileData
import Foundation
import SharedConductorData
import SQLiteData
import Testing

struct CloudContentPersistenceTests {
    @Test("Session snapshots paginate into canonical rows and retain unknown status")
    func sessionReconciliation() throws {
        let database = try appDatabase()
        let workspace = cloudWorkspace()
        let localWorkspace = Workspace.preview(id: "local-workspace")
        let localSession = Session.preview(
            id: "local-session",
            workspaceID: localWorkspace.id
        )
        try database.write { db in
            try Workspace.insert { [workspace, localWorkspace] }.execute(db)
            try Session.insert { localSession }.execute(db)
            try CloudSessionPersistence.persist(
                sessionSnapshot(
                    workspace: workspace,
                    sessionIDs: ["one", "two"],
                    status: .init(rawValue: "future-status")
                ),
                in: db
            )
        }

        let firstSessions = try database.read { db in
            try Session
                .where { $0.workspaceID.eq(workspace.id) }
                .order(by: \.id)
                .fetchAll(db)
        }
        #expect(firstSessions.map(\.id) == ["one", "two"])
        #expect(firstSessions.allSatisfy { $0.status.rawValue == "future-status" })

        try database.write { db in
            try CloudSessionPersistence.persist(
                sessionSnapshot(
                    workspace: workspace,
                    sessionIDs: ["two"],
                    status: .idle
                ),
                in: db
            )
        }

        try database.read { db in
            #expect(try Session.find("one").fetchOne(db) == nil)
            #expect(try Session.find("two").fetchOne(db)?.status == .idle)
            #expect(try Session.find(localSession.id).fetchOne(db) == localSession)
        }
    }

    @Test("Full and incremental transcript updates do not duplicate canonical rows")
    func transcriptReconciliation() throws {
        let database = try appDatabase()
        let workspace = cloudWorkspace()
        let session = Session.preview(id: "session", workspaceID: workspace.id)
        try database.write { db in
            try Workspace.insert { workspace }.execute(db)
            try Session.insert { session }.execute(db)
            try CloudSessionMetadata
                .insert {
                    CloudSessionMetadata(
                        sessionID: session.id,
                        workspaceID: workspace.id,
                        accountID: "account",
                        lastSeenGeneration: "session-generation"
                    )
                }
                .execute(db)
            try CloudMessagePersistence.persist(
                transcriptSnapshot(
                    sessionID: session.id,
                    messages: [userMessage(id: "stable", text: "old")],
                    isFullSnapshot: true
                ),
                in: db
            )
            try CloudMessagePersistence.persist(
                transcriptSnapshot(
                    sessionID: session.id,
                    messages: [userMessage(id: "stable", text: "updated")],
                    isFullSnapshot: false
                ),
                in: db
            )
        }

        try database.read { db in
            let messages = try Message
                .where { $0.sessionID.eq(session.id) }
                .fetchAll(db)
            #expect(messages.count == 1)
            #expect(messages.first?.id == "stable")
            #expect(messages.first?.content == "updated")
            #expect(
                try CloudMessageMetadata
                    .where { $0.sessionID.eq(session.id) }
                    .fetchCount(db) == 1
            )
        }
    }

    @Test("Cloud cache cleanup removes owned content and preserves local rows")
    func narrowlyScopedCleanup() throws {
        let database = try appDatabase()
        let cloudWorkspace = cloudWorkspace()
        let localWorkspace = Workspace.preview(id: "local-workspace")
        let localSession = Session.preview(
            id: "local-session",
            workspaceID: localWorkspace.id
        )
        let localMessage = Message(
            id: "local-message",
            sessionID: localSession.id,
            role: .user,
            content: "local",
            createdAt: date,
            sentAt: date
        )
        try database.write { db in
            try Workspace.insert { [cloudWorkspace, localWorkspace] }.execute(db)
            try Session.insert { localSession }.execute(db)
            try Message.insert { localMessage }.execute(db)
            try CloudWorkspaceMetadata
                .insert {
                    CloudWorkspaceMetadata(
                        workspaceID: cloudWorkspace.id,
                        accountID: "account",
                        lastSeenGeneration: "workspace-generation"
                    )
                }
                .execute(db)
            try CloudSessionPersistence.persist(
                sessionSnapshot(
                    workspace: cloudWorkspace,
                    sessionIDs: ["cloud-session"],
                    status: .idle
                ),
                in: db
            )
            try CloudMessagePersistence.persist(
                transcriptSnapshot(
                    sessionID: "cloud-session",
                    messages: [
                        userMessage(
                            id: "cloud-message",
                            sessionID: "cloud-session",
                            text: "cloud"
                        ),
                    ],
                    isFullSnapshot: true
                ),
                in: db
            )
            try CloudWorkspaceMetadata.clearCachedRows(in: db)
        }

        try database.read { db in
            #expect(try Workspace.find(cloudWorkspace.id).fetchOne(db) == nil)
            #expect(try Session.find("cloud-session").fetchOne(db) == nil)
            #expect(try Message.find("cloud-message").fetchOne(db) == nil)
            #expect(try Workspace.find(localWorkspace.id).fetchOne(db) == localWorkspace)
            #expect(try Session.find(localSession.id).fetchOne(db) == localSession)
            #expect(try Message.find(localMessage.id).fetchOne(db) == localMessage)
        }
    }

    private let date = Date(timeIntervalSince1970: 1_783_555_200)

    private func cloudWorkspace() -> Workspace {
        Workspace.preview(
            id: "cloud-workspace",
            hostingServerURL: Workspace.conductorCloudHostingServerURL
        )
    }

    private func sessionSnapshot(
        workspace: Workspace,
        sessionIDs: [Session.ID],
        status: CloudSessionStatusResponse.Status
    ) -> CloudSessionSnapshot {
        let cloudWorkspace = CloudWorkspace(
            id: workspace.id,
            name: workspace.workspaceName ?? workspace.id,
            createdAt: workspace.createdAt,
            lastActivityAt: workspace.updatedAt
        )
        let sessions = sessionIDs.map {
            CloudSession(
                id: $0,
                deepLink: CloudAPIClient.productionBaseURL,
                name: $0,
                model: Session.Model.gpt_5_6_sol.rawValue
            )
        }
        return CloudSessionSnapshot(
            accountID: "account",
            workspace: cloudWorkspace,
            sessions: sessions,
            statuses: Dictionary(
                uniqueKeysWithValues: sessions.map {
                    (
                        $0.id,
                        CloudSessionStatusResponse(
                            workspaceID: workspace.id,
                            sessionID: $0.id,
                            status: status,
                            updatedAt: date
                        )
                    )
                }
            )
        )
    }

    private func transcriptSnapshot(
        sessionID: Session.ID,
        messages: [CloudTranscriptMessage],
        isFullSnapshot: Bool
    ) -> CloudTranscriptSnapshot {
        CloudTranscriptSnapshot(
            accountID: "account",
            sessionID: sessionID,
            status: CloudSessionStatusResponse(
                workspaceID: "cloud-workspace",
                sessionID: sessionID,
                status: .idle,
                updatedAt: date
            ),
            messages: messages,
            isFullSnapshot: isFullSnapshot
        )
    }

    private func userMessage(
        id: String,
        sessionID: Session.ID = "session",
        text: String
    ) -> CloudTranscriptMessage {
        CloudTranscriptMessage(
            id: id,
            sessionID: sessionID,
            sessionIndex: 1,
            type: .init(rawValue: "event"),
            content: .object([
                "type": .string("userMessage"),
                "message": .string(text),
            ]),
            receivedAt: date
        )
    }
}
