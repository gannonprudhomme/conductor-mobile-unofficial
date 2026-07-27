//
//  CloudWorkspaceFeatureTests.swift
//  ConductorChatTests
//
//  Created by Gannon Prudomme on 7/24/26.
//

import ComposableArchitecture
import ConductorCloud
import ConductorMobileData
import Foundation
import SharedConductorData
import Sharing
@testable import ConductorChat
import Testing

@MainActor
struct CloudWorkspaceFeatureTests {
    @Test("A created workspace starts in the shared chat with its prompt intact")
    func createdWorkspaceStartsInSharedChat() throws {
        try withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let state = CloudWorkspaceFeature.State(
                workspaceID: "workspace-1",
                fallbackTitle: "Cloud workspace",
                initialSessionID: "session-1",
                initialPrompt: "Run the tests."
            )
            let chat = try #require(state.chat)

            #expect(chat.backend == .cloud)
            #expect(chat.messageDraft == "Run the tests.")
            #expect(chat.sessionID == "session-1")
            #expect(chat.shouldSendInitialPrompt)
        }
    }

    @Test("An API workspace snapshot selects the shared chat reducer")
    func snapshotSelectsSharedChat() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let workspace = CloudWorkspace(
                id: "workspace-1",
                name: "Cloud workspace",
                createdAt: .now,
                deepLink: CloudAPIClient.productionBaseURL
            )
            let session = CloudSession(
                id: "session-1",
                deepLink: CloudAPIClient.productionBaseURL,
                name: "Cloud chat",
                model: Session.Model.gpt_5_6_sol.rawValue
            )
            let workingSession = CloudSession(
                id: "session-2",
                deepLink: CloudAPIClient.productionBaseURL,
                name: "Working chat",
                model: Session.Model.gpt_5_6_sol.rawValue
            )
            let lifecycle = CloudWorkspaceStatusResponse(
                workspaceID: workspace.id,
                status: .ready,
                updatedAt: .now
            )
            let clock = TestClock()
            let store = TestStore(
                initialState: CloudWorkspaceFeature.State(
                    workspaceID: workspace.id,
                    fallbackTitle: workspace.name
                )
            ) {
                CloudWorkspaceFeature()
            } withDependencies: {
                $0.cloudAPIClient.sessionStatus = { sessionID in
                    CloudSessionStatusResponse(
                        workspaceID: workspace.id,
                        sessionID: sessionID,
                        status: sessionID == workingSession.id ? .working : .idle,
                        updatedAt: .now
                    )
                }
                $0.continuousClock = clock
            }

            await store.send(
                .response(
                    .success(
                        CloudWorkspaceFeature.Snapshot(
                            lifecycle: lifecycle,
                            sessions: [session, workingSession],
                            workspace: workspace
                        )
                    )
                )
            ) {
                $0.chat = Chat.State(
                    cloudSession: session,
                    workspaceID: workspace.id
                )
                $0.hasLoadedInitialSessionSnapshot = true
                $0.isLoading = false
                $0.lifecycle = lifecycle
                $0.selectedSessionID = session.id
                $0.sessions = [session, workingSession]
                $0.workspace = workspace
            }
            await store.receive(\.sessionStatusesResponse.success) {
                $0.sessionStatuses = [
                    session.id: .idle,
                    workingSession.id: .working,
                ]
            }

            #expect(store.state.chat?.backend == .cloud)
            #expect(store.state.activeSessions.map(\.id) == [
                session.id,
                workingSession.id,
            ])
            #expect(
                store.state.activeSessions.map(\.status) == [
                    .idle,
                    .working,
                ]
            )
            await store.send(.viewDisappeared)
        }
    }

    @Test("The shared new-tab button creates and selects a cloud session")
    func createSession() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let workspaceID = "workspace-1"
            let firstSession = CloudSession(
                id: "session-1",
                deepLink: CloudAPIClient.productionBaseURL,
                name: "First",
                model: Session.Model.gpt_5_6_sol.rawValue
            )
            let createdSession = CloudSession(
                id: "session-2",
                deepLink: CloudAPIClient.productionBaseURL,
                name: "Second",
                model: Session.Model.gpt_5_6_sol.rawValue
            )
            var state = CloudWorkspaceFeature.State(
                workspaceID: workspaceID,
                fallbackTitle: "Cloud workspace"
            )
            state.isLoading = false
            state.sessions = [firstSession]
            state.selectedSessionID = firstSession.id
            state.chat = Chat.State(
                cloudSession: firstSession,
                workspaceID: workspaceID
            )
            let store = TestStore(initialState: state) {
                CloudWorkspaceFeature()
            } withDependencies: {
                $0.cloudAPIClient.createSession = { request in
                    #expect(
                        request == CloudCreateSessionRequest(
                            workspaceID: workspaceID,
                            agent: Session.AgentType.codex.rawValue,
                            model: Session.Model.gpt_5_6_sol.rawValue,
                            fastMode: false
                        )
                    )
                    return createdSession
                }
            }

            await store.send(.createSessionButtonTapped) {
                $0.isCreatingSession = true
            }
            await store.receive(\.createSessionResponse.success) {
                $0.chat = Chat.State(
                    cloudSession: createdSession,
                    workspaceID: workspaceID,
                    shouldFocusMessageField: true
                )
                $0.isCreatingSession = false
                $0.selectedSessionID = createdSession.id
                $0.sessions = [firstSession, createdSession]
            }

            #expect(store.state.activeSessions.map(\.id) == [
                firstSession.id,
                createdSession.id,
            ])
            #expect(store.state.chat?.shouldFocusMessageField == true)
        }
    }
}
