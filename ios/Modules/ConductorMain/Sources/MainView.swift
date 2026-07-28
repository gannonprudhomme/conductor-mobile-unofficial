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

        public var path = StackState<Path.State>()
        @Presents public var settings: ConductorSettings.State?
        public var workspaces = Workspaces.State()

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
        case path(StackActionOf<Path>)
        case settings(PresentationAction<ConductorSettings.Action>)
        case task
        case workspaces(Workspaces.Action)
    }

    @Dependency(\.cloudCredentialClient) var cloudCredentialClient
    @Dependency(\.defaultDatabase) var database

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
                    guard state.cloudConfiguration != nil else {
                        return .send(.workspaces(.task))
                    }
                    return .run { [cloudCredentialClient] send in
                        await send(
                            .cloudCredentialReconciliationResult(
                                await Result {
                                    try await cloudCredentialClient.loadAPIKey()
                                }
                            )
                        )
                    }

                case .appBecameActive:
                    return .send(.workspaces(.appBecameActive))

                case .appEnteredBackground:
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

                // We handle the displaying of Settings in here so we can keep ConductorSettings + ConductorWorkspaces decoupled
                // akin to how modules are decoupled for push navigation
                case .workspaces(.settingsButtonTapped):
                    state.settings = ConductorSettings.State()
                    return .none

                case let .workspaces(.workspaceCreated(creation)):
                    state.path.append(
                        .workspaceChat(
                            WorkspaceChat.State(
                                workspaceWithRepository: creation.workspace,
                                selectedModel: creation.selectedModel,
                                selectedReasoningEffort: creation.selectedReasoningEffort,
                                shouldFocusMessageField: true
                            )
                        )
                    )
                    return .none

                case let .workspaces(.workspaceTapped(item)):
                    guard !item.isCloudOnly else {
                        return .none
                    }
                    state.path.append(
                        .workspaceChat(
                            WorkspaceChat.State(workspaceWithRepository: item)
                        )
                    )
                    return .none

                case let .path(
                    .element(
                        id: id,
                        action: .workspaceChat(.delegate(.workspaceArchived))
                    )
                ):
                    state.path.pop(from: id)
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
