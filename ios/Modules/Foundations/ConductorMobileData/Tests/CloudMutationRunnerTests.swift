//
//  CloudMutationRunnerTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/29/26.
//

import ComposableArchitecture
import ConductorCloud
import Foundation
import Sharing
import SharedConductorData
import SQLiteData
@testable import ConductorMobileData
import Testing

struct CloudMutationRunnerTests {
    @Test("Credential replacement rolls back mutations that never dispatched")
    func credentialReplacementRollsBackUnstartedMutation() async throws {
        let accountID = "account"
        let generation = UUID(44)
        let canonicalSessionID = "provisional-session"
        let pending = try CloudPendingMutation(
            attemptID: UUID(45),
            accountID: accountID,
            credentialGeneration: generation,
            operation: .createSession,
            resourceKind: .session,
            request: CloudCreateSessionRequest(
                workspaceID: "remote-workspace",
                sessionID: "remote-session",
                agent: Session.AgentType.codex.rawValue
            ),
            canonicalWorkspaceID: "workspace",
            remoteWorkspaceID: "remote-workspace",
            canonicalSessionID: canonicalSessionID,
            remoteSessionID: "remote-session"
        )

        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
            $0.cloudMutationRunner = .liveValue
        } operation: {
            @Dependency(\.cloudMutationRunner) var runner
            @Dependency(\.defaultDatabase) var database
            try await database.write { database in
                try Session.insert {
                    Session.preview(
                        id: canonicalSessionID,
                        workspaceID: "workspace"
                    )
                }
                .execute(database)
                try CloudSessionMetadata.insert {
                    CloudSessionMetadata(
                        canonicalSessionID: canonicalSessionID,
                        cloudSessionID: "remote-session",
                        workspaceID: "workspace",
                        accountID: accountID,
                        listOrder: 0,
                        refreshGeneration: "provisional"
                    )
                }
                .execute(database)
                try CloudPendingMutation.insert { pending }.execute(database)
            }

            await runner.cancelAndAwait(accountID, generation)

            let persisted = try await database.read { database in
                (
                    mutation: try CloudPendingMutation
                        .find(pending.attemptID)
                        .fetchOne(database),
                    session: try Session
                        .find(canonicalSessionID)
                        .fetchOne(database),
                    metadata: try CloudSessionMetadata
                        .find(canonicalSessionID)
                        .fetchOne(database)
                )
            }
            #expect(persisted.mutation == nil)
            #expect(persisted.session == nil)
            #expect(persisted.metadata == nil)
        }
    }

    @Test("Startup dispatches only mutations that never started")
    func startupRecovery() async throws {
        let accountID = "account"
        let generation = UUID(40)
        let dispatchedSessionIDs = LockIsolated<[String]>([])
        let ready = try mutation(
            attemptID: UUID(41),
            accountID: accountID,
            generation: generation,
            remoteSessionID: "ready-session"
        )
        let started = try mutation(
            attemptID: UUID(42),
            accountID: accountID,
            generation: generation,
            remoteSessionID: "started-session",
            dispatchStartedAt: Date(timeIntervalSince1970: 1)
        )
        let canceledDelivery = MessageDeliveryAttempt(
            attemptID: UUID(47),
            route: .cloud,
            accountID: accountID,
            credentialGeneration: generation,
            cloudDeliveryState: CloudSendMessageResponse.State.queued.rawValue,
            canonicalWorkspaceID: "workspace",
            remoteWorkspaceID: "remote-workspace",
            canonicalSessionID: "ready-session",
            remoteSessionID: "ready-session",
            content: "Queued prompt",
            model: .gpt5_5,
            isFastModeEnabled: false,
            mode: .sent,
            reasoningEffort: .high,
            submittedDraft: "Queued prompt",
            state: .accepted
        )
        let canonicalSessionID = CloudCanonicalID.session(
            accountID: accountID,
            remoteSessionID: "created-session"
        )
        let created = try CloudPendingMutation(
            attemptID: UUID(43),
            accountID: accountID,
            credentialGeneration: generation,
            operation: .createSession,
            resourceKind: .session,
            request: CloudCreateSessionRequest(
                workspaceID: "remote-workspace",
                sessionID: "created-session",
                agent: Session.AgentType.codex.rawValue,
                effort: Session.ReasoningEffort.high.rawValue,
                fastMode: false
            ),
            canonicalWorkspaceID: "workspace",
            remoteWorkspaceID: "remote-workspace",
            canonicalSessionID: canonicalSessionID,
            remoteSessionID: "created-session"
        )
        let workspaceCreationPayload = CloudWorkspaceCreationPayload(
            request: CloudCreateWorkspaceRequest(
                projectID: "project",
                sessionName: "Conductor Mobile recovery-token",
                agent: Session.AgentType.codex.rawValue,
                model: Session.Model.gpt_5_6_sol.rawValue,
                effort: Session.ReasoningEffort.high.rawValue
            ),
            canonicalRepositoryID: "repository",
            projectID: "project",
            repositoryURL: nil,
            selectedModel: .gpt_5_6_sol,
            selectedReasoningEffort: .high,
            prompt: "Initial prompt",
            baselineRemoteWorkspaceIDs: ["existing-workspace"]
        )
        let recoveredWorkspace = try CloudPendingMutation(
            attemptID: UUID(46),
            accountID: accountID,
            credentialGeneration: generation,
            operation: .createWorkspace,
            resourceKind: .workspace,
            request: workspaceCreationPayload,
            dispatchStartedAt: Date(timeIntervalSince1970: 3)
        )

        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
            $0.continuousClock = ContinuousClock()
            $0.cloudMutationRunner = .liveValue
            $0.cloudAPIClient.cancelSession = {
                expectedAccountID,
                sessionID in
                #expect(expectedAccountID == accountID)
                dispatchedSessionIDs.withValue { $0.append(sessionID) }
                return try JSONDecoder().decode(
                    CloudCancelSessionResponse.self,
                    from: Data(
                        """
                        {
                          "workspaceId": "remote-workspace",
                          "sessionId": "\(sessionID)",
                          "status": "idle",
                          "canceledQueuedMessages": \(sessionID == "ready-session" ? 1 : 0)
                        }
                        """.utf8
                    )
                )
            }
            $0.cloudAPIClient.createSession = {
                expectedAccountID,
                request in
                #expect(expectedAccountID == accountID)
                #expect(request.sessionID == "created-session")
                return CloudSession(
                    id: request.sessionID,
                    deepLink: try #require(
                        URL(string: "https://conductor.build/session")
                    ),
                    resolvedModel: Session.Model.gpt_5_6_sol.rawValue,
                    effort: Session.ReasoningEffort.high.rawValue,
                    agent: Session.AgentType.codex.rawValue,
                    fastMode: false
                )
            }
            $0.cloudAPIClient.recoverWorkspaceCreation = {
                expectedAccountID,
                request in
                #expect(expectedAccountID == accountID)
                #expect(request.baselineWorkspaceIDs == ["existing-workspace"])
                #expect(request.projectID == "project")
                #expect(
                    request.sessionName == "Conductor Mobile recovery-token"
                )
                return CloudCreateWorkspaceResponse(
                    workspaceID: "recovered-workspace",
                    sessionID: "recovered-session",
                    deepLink: try #require(
                        URL(string: "https://conductor.build/session")
                    )
                )
            }
        } operation: {
            @Dependency(\.cloudMutationRunner) var runner
            @Dependency(\.defaultDatabase) var database
            @Shared(.cloudConfiguration) var configuration
            $configuration.withLock {
                $0 = CloudConfiguration(
                    accountID: accountID,
                    credentialGeneration: generation
                )
            }
            try await database.write { database in
                try Session.insert {
                    Session.preview(
                        id: canonicalSessionID,
                        workspaceID: "workspace",
                        model: Session.Model(rawValue: ""),
                        codexThinkingLevel: nil,
                        isFastModeEnabled: nil
                    )
                }
                .execute(database)
                try CloudPendingMutation
                    .insert {
                        [ready, started, created, recoveredWorkspace]
                    }
                    .execute(database)
                try MessageDeliveryAttempt.insert { canceledDelivery }
                    .execute(database)
            }

            try await runner.start()
            let clock = ContinuousClock()
            for _ in 0..<100 {
                let state = try await database.read { database in
                    try CloudPendingMutation.find(ready.attemptID)
                        .fetchOne(database)?
                        .mutationState
                }
                let createdState = try await database.read { database in
                    try CloudPendingMutation.find(created.attemptID)
                        .fetchOne(database)?
                        .mutationState
                }
                let recoveredState = try await database.read { database in
                    try CloudPendingMutation
                        .find(recoveredWorkspace.attemptID)
                        .fetchOne(database)?
                        .mutationState
                }
                if state == .accepted,
                   createdState == .accepted,
                   recoveredState == .accepted {
                    break
                }
                try await clock.sleep(for: .milliseconds(20))
            }
            try await clock.sleep(for: .milliseconds(300))

            let mutations = try await database.read { database in
                try CloudPendingMutation.all.fetchAll(database)
            }
            let states = Dictionary(
                uniqueKeysWithValues: mutations.map {
                    ($0.attemptID, $0.mutationState)
                }
            )
            #expect(states[ready.attemptID] == .accepted)
            #expect(states[started.attemptID] == .indeterminate)
            #expect(states[created.attemptID] == .accepted)
            #expect(states[recoveredWorkspace.attemptID] == .accepted)
            #expect(dispatchedSessionIDs.value == ["ready-session"])
            let canceledDeliveryExists = try await database.read { database in
                try MessageDeliveryAttempt
                    .find(canceledDelivery.attemptID)
                    .fetchOne(database) != nil
            }
            #expect(!canceledDeliveryExists)
            let hydratedSession = try await database.read { database in
                try Session.find(canonicalSessionID).fetchOne(database)
            }
            #expect(hydratedSession?.model == .gpt_5_6_sol)
            #expect(hydratedSession?.codexThinkingLevel == .high)
            #expect(hydratedSession?.isFastModeEnabled == false)
            let recoveredDelivery = try await database.read { database in
                try MessageDeliveryAttempt.all.fetchAll(database)
            }
            #expect(recoveredDelivery.count == 1)
            #expect(recoveredDelivery.first?.content == "Initial prompt")
            #expect(
                recoveredDelivery.first?.remoteSessionID
                    == "recovered-session"
            )
        }
    }
}

private func mutation(
    attemptID: UUID,
    accountID: String,
    generation: UUID,
    remoteSessionID: String,
    dispatchStartedAt: Date? = nil
) throws -> CloudPendingMutation {
    try CloudPendingMutation(
        attemptID: attemptID,
        accountID: accountID,
        credentialGeneration: generation,
        operation: .cancelSession,
        resourceKind: .session,
        request: CloudSendMessageRequest(
            messageID: "unused",
            message: "unused"
        ),
        remoteWorkspaceID: "remote-workspace",
        remoteSessionID: remoteSessionID,
        dispatchStartedAt: dispatchStartedAt,
        createdAt: Date(
            timeIntervalSince1970: attemptID == UUID(41) ? 1 : 2
        )
    )
}
