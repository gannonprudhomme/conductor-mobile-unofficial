//
//  MainView.swift
//  ConductorMain
//
//  Created by Gannon Prudomme on 7/12/26.
//

import ComposableArchitecture
import ConductorChat
import ConductorCloud
import ConductorMobileData
import ConductorSettings
import ConductorWorkspaces
import Sharing
import SQLiteData
import SwiftUI

@Reducer
public struct Main: Sendable {
    @Reducer
    public enum Path {
        case workspaceChat(WorkspaceChat)
    }

    @ObservableState
    public struct State: Equatable {
        @Shared(.cloudConfiguration)
        public var cloudConfiguration

        var cachedWorkspaceChat: WorkspaceChat.State?
        public var path = StackState<Path.State>()
        @Presents public var settings: ConductorSettings.State?
        public var workspaces = Workspaces.State()
        var isInBackground = false

        public init() {
            // A fresh install needs at least one usable local or cloud connection.
            let settings = ConductorSettings.State()
            self.settings = settings.requiresConnectionConfiguration ? settings : nil
        }
    }

    public enum Action {
        case appBecameActive
        case appEnteredBackground
        case cloudCacheCleanupResult(Result<Void, any Error>)
        case cloudCredentialReconciliationResult(Result<String?, any Error>)
        case messageDeliveryOutboxResult(Result<Void, any Error>)
        case cloudMutationRunnerResult(Result<Void, any Error>)
        case cloudWorkspaceCompletionConsumed(Result<Void, any Error>)
        case path(StackActionOf<Path>)
        case settings(PresentationAction<ConductorSettings.Action>)
        case task
        case workspaces(Workspaces.Action)
    }

    @Dependency(\.cloudCredentialClient) var cloudCredentialClient
    @Dependency(\.cloudMutationRunner) var cloudMutationRunner
    @Dependency(\.defaultDatabase) var database
    @Dependency(\.desktopClient) var desktopClient
    @Dependency(\.messageDeliveryOutbox) var messageDeliveryOutbox

    public init() {
    }

    public var body: some ReducerOf<Self> {
        CombineReducers {
            Scope(state: \.workspaces, action: \.workspaces) {
                Workspaces()
            }
            Reduce { state, action in
                switch action {
                case .task:
                    let startRunner: Effect<Action> = .run {
                        [cloudMutationRunner] send in
                        await send(
                            .cloudMutationRunnerResult(
                                await Result {
                                    try await cloudMutationRunner.start()
                                }
                            )
                        )
                    }
                    let startOutbox: Effect<Action> = .run {
                        [messageDeliveryOutbox] send in
                        await send(
                            .messageDeliveryOutboxResult(
                                await Result {
                                    try await messageDeliveryOutbox.start()
                                }
                            )
                        )
                    }
                    guard state.cloudConfiguration != nil else {
                        return .merge(
                            startRunner,
                            startOutbox,
                            .send(.workspaces(.task))
                        )
                    }
                    return .merge(
                        startRunner,
                        startOutbox,
                        .run { [cloudCredentialClient] send in
                            await send(
                                .cloudCredentialReconciliationResult(
                                    await Result {
                                        try await cloudCredentialClient
                                            .loadAPIKey()
                                    }
                                )
                            )
                        }
                    )

                case let .cloudMutationRunnerResult(.failure(error)):
                    return .send(.workspaces(.loadWorkspacesFailed(error)))

                case .cloudMutationRunnerResult(.success):
                    return .none

                case let .messageDeliveryOutboxResult(.failure(error)):
                    return .send(.workspaces(.loadWorkspacesFailed(error)))

                case .messageDeliveryOutboxResult(.success):
                    return .none

                case let .cloudWorkspaceCompletionConsumed(.failure(error)):
                    return .send(.workspaces(.loadWorkspacesFailed(error)))

                case .cloudWorkspaceCompletionConsumed(.success):
                    return .none

                case .appBecameActive:
                    guard state.isInBackground else {
                        return .none
                    }
                    state.isInBackground = false
                    return .send(.workspaces(.appBecameActive))

                case .appEnteredBackground:
                    guard !state.isInBackground else {
                        return .none
                    }
                    state.isInBackground = true
                    return .send(.workspaces(.appEnteredBackground))

                case let .cloudCredentialReconciliationResult(result):
                    switch result {
                    case .failure:
                        // A Keychain read error is not proof that the credential is absent.
                        return .send(.workspaces(.task))

                    case .success(.some):
                        return .send(.workspaces(.task))

                    case .success(nil):
                        state.$cloudConfiguration.withLock { $0 = nil }
                        if state.cachedWorkspaceChat?.workspace.isCloudHosted == true {
                            state.cachedWorkspaceChat = nil
                        }
                        let settings = ConductorSettings.State()
                        if settings.requiresConnectionConfiguration {
                            state.settings = settings
                        }
                        return .merge(
                            .send(.workspaces(.task)),
                            .run { [database] send in
                                await send(
                                    .cloudCacheCleanupResult(
                                        await Result {
                                            try await database.write { db in
                                                try CloudWorkspaceMetadata
                                                    .clearCachedRows(in: db)
                                            }
                                        }
                                    )
                                )
                            }
                        )
                    }

                case let .cloudCacheCleanupResult(.failure(error)):
                    return .send(.workspaces(.loadWorkspacesFailed(error)))

                case .cloudCacheCleanupResult(.success):
                    return .none

                case .settings(
                    .presented(.cloudCredentialDeleteResult(.success))
                ):
                    if state.cachedWorkspaceChat?.workspace.isCloudHosted == true {
                        state.cachedWorkspaceChat = nil
                    }
                    return .none

                // We handle the displaying of Settings in here so we can keep ConductorSettings + ConductorWorkspaces decoupled
                // akin to how modules are decoupled for push navigation
                case .workspaces(.settingsButtonTapped):
                    state.settings = ConductorSettings.State()
                    return .none

                case let .workspaces(.workspaceCreated(creation)):
                    if let requestLease = creation.requestLease {
                        guard desktopClient.isRequestLeaseValid(
                            lease: requestLease
                        ) else {
                            return .none
                        }
                    }
                    let alreadyPresented = state.path.contains { destination in
                        guard case let .workspaceChat(workspaceChat) = destination else {
                            return false
                        }
                        return workspaceChat.workspace.id == creation.workspace.id
                    }
                    if !alreadyPresented {
                        state.path.append(
                            .workspaceChat(
                                WorkspaceChat.State(
                                    workspaceWithRepository: creation.workspace,
                                    selectedSessionID: creation.selectedSessionID,
                                    selectedModel: creation.selectedModel,
                                    selectedReasoningEffort: creation.selectedReasoningEffort,
                                    shouldFocusMessageField: true
                                )
                            )
                        )
                    }
                    guard let completionID = creation.completionID else {
                        return .none
                    }
                    return .run { send in
                        await send(
                            .cloudWorkspaceCompletionConsumed(
                                await Result {
                                    try await database.write { database in
                                        try CloudMutationOutcome
                                            .find(completionID)
                                            .update {
                                                $0.consumedAt = #bind(Date())
                                            }
                                            .execute(database)
                                    }
                                }
                            )
                        )
                    }

                case let .workspaces(.workspaceTapped(item)):
                    let workspaceChat: WorkspaceChat.State
                    if let cachedWorkspaceChat = state.cachedWorkspaceChat,
                       cachedWorkspaceChat.workspace.id == item.id {
                        workspaceChat = cachedWorkspaceChat
                        state.cachedWorkspaceChat = nil
                    } else {
                        workspaceChat = WorkspaceChat.State(
                            workspaceWithRepository: item
                        )
                    }
                    state.path.append(
                        .workspaceChat(workspaceChat)
                    )
                    return .none

                case let .path(.popFrom(id)):
                    if case let .workspaceChat(workspaceChat) = state.path[id: id],
                       workspaceChat.canRestoreWarmPresentation {
                        state.cachedWorkspaceChat = workspaceChat
                    }
                    return .none

                case let .path(
                    .element(
                        id: id,
                        action: .workspaceChat(.delegate(.workspaceArchived))
                    )
                ):
                    state.path.pop(from: id)
                    return .none

                case .path(
                    .element(
                        id: _,
                        action: .workspaceChat(.delegate(.openSettings))
                    )
                ):
                    state.settings = ConductorSettings.State()
                    return .none

                case .path, .settings, .workspaces:
                    return .none
                }
            }
        }
        .ifLet(\.$settings, action: \.settings) {
            ConductorSettings()
        }
        .forEach(\.path, action: \.path)
    }
}

extension Main.Path.State: Equatable { }

public struct MainView: View {
    @Bindable var store: StoreOf<Main>
    @Environment(\.scenePhase) private var scenePhase

    public init(store: StoreOf<Main>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
            WorkspacesView(
                store: store.scope(state: \.workspaces, action: \.workspaces)
            )
            .sheet(item: $store.scope(state: \.settings, action: \.settings)) { store in
                ConductorSettingsView(store: store)
            }
        } destination: { store in
            switch store.case {
            case let .workspaceChat(store):
                WorkspaceChatView(store: store)
            }
        }
        .task {
            // MainView stays mounted while destinations are pushed, keeping the workspace socket
            // alive while the root WorkspacesView is off-screen.
            await store.send(.task).finish()
        }
        .onChange(of: scenePhase) { _, scenePhase in
            switch scenePhase {
            case .active:
                store.send(.appBecameActive)

            case .background:
                store.send(.appEnteredBackground)

            case .inactive:
                break

            @unknown default:
                break
            }
        }
        .sensoryFeedback(.error, trigger: store.workspaces.connectionStatus) {
            $0 == .connected && $1 == .disconnected
        }
    }
}

#Preview {
    MainView(
        store: Store(initialState: Main.State()) {
            Main()
        }
    )
    .preferredColorScheme(.dark)
}
