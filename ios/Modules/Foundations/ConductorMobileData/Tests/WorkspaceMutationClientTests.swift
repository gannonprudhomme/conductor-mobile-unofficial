//
//  WorkspaceMutationClientTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/29/26.
//

import ConductorCloud
import Dependencies
import Foundation
import Sharing
import SharedConductorData
import SQLiteData
@testable import ConductorMobileData
import Testing

struct WorkspaceMutationClientTests {
    @Test("Cloud workspace creation carries a request-specific recovery marker")
    func workspaceCreationRecoveryMarker() async throws {
        let accountID = "account"
        let repository = Repository.preview(id: "repository")
        let candidate = CloudWorkspaceCreationCandidate(
            repository: repository,
            projectID: "project",
            repositoryURL: nil
        )

        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            @Dependency(\.defaultDatabase) var database
            @Shared(.cloudConfiguration) var cloudConfiguration
            $cloudConfiguration.withLock {
                $0 = CloudConfiguration(
                    accountID: accountID,
                    credentialGeneration: UUID(52)
                )
            }
            try await database.write { database in
                try Repository.insert { repository }.execute(database)
                try CloudProjectRepositoryMapping.insert {
                    CloudProjectRepositoryMapping(
                        accountID: accountID,
                        cloudProjectID: candidate.projectID,
                        canonicalRepositoryID: repository.id,
                        projectName: "Project",
                        gitRemote: "https://example.test/repository.git",
                        refreshGeneration: "generation"
                    )
                }
                .execute(database)
            }

            try await WorkspaceMutationClient.liveValue.createWorkspace(
                route: .cloud(accountID: accountID),
                candidate: candidate,
                prompt: "Implement it",
                model: .gpt_5_6_sol,
                reasoningEffort: .high
            )

            let attempt = try await database.read { database in
                try #require(
                    try CloudPendingMutation.all.fetchOne(database)
                )
            }
            let payload = try attempt.request(
                as: CloudWorkspaceCreationPayload.self
            )
            #expect(
                payload.request.sessionName
                    == "Conductor Mobile \(attempt.attemptID.uuidString.lowercased())"
            )
        }
    }

    @Test("A completed Cloud cancel does not block a later cancel")
    func repeatedCloudCancel() async throws {
        let accountID = "account"
        let generation = UUID(51)
        let workspace = Workspace.preview(id: "workspace")
        let session = Session.preview(
            id: "session",
            workspaceID: workspace.id
        )

        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            @Dependency(\.defaultDatabase) var database
            @Shared(.cloudConfiguration) var cloudConfiguration
            $cloudConfiguration.withLock {
                $0 = CloudConfiguration(
                    accountID: accountID,
                    credentialGeneration: generation
                )
            }
            try await database.write { database in
                try Workspace.insert { workspace }.execute(database)
                try Session.insert { session }.execute(database)
                try CloudWorkspaceMetadata.insert {
                    CloudWorkspaceMetadata(
                        workspaceID: workspace.id,
                        accountID: accountID,
                        remoteWorkspaceID: "remote-workspace",
                        lastSeenGeneration: "generation"
                    )
                }
                .execute(database)
                try CloudSessionMetadata.insert {
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

            let route = WorkspaceMutationRoute.cloud(
                accountID: accountID,
                remoteWorkspaceID: "remote-workspace"
            )
            try await WorkspaceMutationClient.liveValue.cancelSession(
                route: route,
                canonicalWorkspaceID: workspace.id,
                canonicalSessionID: session.id
            )
            try await database.write { database in
                let first = try #require(
                    try CloudPendingMutation.all.fetchOne(database)
                )
                _ = try CloudPendingMutation.compareAndSetState(
                    attemptID: first.attemptID,
                    from: .submitting,
                    to: .accepted,
                    at: Date(),
                    in: database
                )
            }

            try await WorkspaceMutationClient.liveValue.cancelSession(
                route: route,
                canonicalWorkspaceID: workspace.id,
                canonicalSessionID: session.id
            )

            let attempts = try await database.read { database in
                try CloudPendingMutation.all.fetchAll(database)
            }
            #expect(attempts.count == 2)
            #expect(attempts.map(\.mutationState).contains(.accepted))
            #expect(attempts.map(\.mutationState).contains(.submitting))
        }
    }

    @Test("New Cloud sessions seed the documented server defaults")
    func cloudSessionDefaults() async throws {
        let accountID = "account"
        let credentialGeneration = UUID(50)
        let workspace = Workspace.preview(id: "workspace")

        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            @Dependency(\.defaultDatabase) var database
            @Shared(.cloudConfiguration) var cloudConfiguration
            @Shared(.mobileModelSettingsOverride) var settings
            $cloudConfiguration.withLock {
                $0 = CloudConfiguration(
                    accountID: accountID,
                    credentialGeneration: credentialGeneration
                )
            }
            $settings.withLock { $0 = nil }
            try await database.write { database in
                try Workspace.insert { workspace }.execute(database)
                try CloudWorkspaceMetadata.insert {
                    CloudWorkspaceMetadata(
                        workspaceID: workspace.id,
                        accountID: accountID,
                        remoteWorkspaceID: "remote-workspace",
                        lastSeenGeneration: "generation"
                    )
                }
                .execute(database)
            }

            let result = try await WorkspaceMutationClient.liveValue
                .createSession(
                    route: .cloud(
                        accountID: accountID,
                        remoteWorkspaceID: "remote-workspace"
                    ),
                    canonicalWorkspaceID: workspace.id,
                    fallbackAgent: .codex
                )

            #expect(result.session.agentType == .codex)
            #expect(result.session.model.rawValue.isEmpty)
            #expect(result.session.codexThinkingLevel == .high)
            #expect(result.session.claudeEffortLevel == nil)
            #expect(result.session.isFastModeEnabled == false)

            let attempt = try await database.read { database in
                try CloudPendingMutation.all.fetchOne(database)
            }
            let request = try #require(attempt).request(
                as: CloudCreateSessionRequest.self
            )
            #expect(request.agent == Session.AgentType.codex.rawValue)
            #expect(request.model == nil)
            #expect(request.effort == Session.ReasoningEffort.high.rawValue)
            #expect(request.fastMode == false)
        }
    }
}
