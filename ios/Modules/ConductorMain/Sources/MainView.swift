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
import SwiftUI

@Reducer
public struct Main: Sendable {
    @Reducer
    public enum Path {
        case cloudWorkspace(CloudWorkspaceFeature)
        case workspaceChat(WorkspaceChat)
    }

    @ObservableState
    public struct State: Equatable {
        public var path = StackState<Path.State>()
        @Presents public var settings: ConductorSettings.State?
        public var workspaces = Workspaces.State()

        public init() {
            // If we're missing the server address (aka on first launch), show Settings immediately.
            let settings = ConductorSettings.State()
            self.settings = settings.isServerAddressMissing ? settings : nil
        }
    }

    public enum Action {
        case path(StackActionOf<Path>)
        case settings(PresentationAction<ConductorSettings.Action>)
        case workspaces(Workspaces.Action)
    }

    public init() {
    }

    public var body: some ReducerOf<Self> {
        CombineReducers {
            Scope(state: \.workspaces, action: \.workspaces) {
                Workspaces()
            }
            Reduce { state, action in
                switch action {
                // We handle the displaying of Settings in here so we can keep ConductorSettings + ConductorWorkspaces decoupled
                // akin to how modules are decoupled for push navigation
                case .workspaces(.settingsButtonTapped):
                    state.settings = ConductorSettings.State()
                    return .none

                case let .workspaces(.cloudCatalog(.workspaceTapped(item))):
                    state.path.append(
                        .cloudWorkspace(
                            CloudWorkspaceFeature.State(
                                workspaceID: item.id,
                                fallbackTitle: item.workspace.name
                            )
                        )
                    )
                    return .none

                case let .workspaces(.cloudWorkspaceCreated(creation)):
                    state.path.append(
                        .cloudWorkspace(
                            CloudWorkspaceFeature.State(
                                workspaceID: creation.response.workspaceID,
                                fallbackTitle: "Cloud workspace",
                                initialSessionID: creation.response.sessionID,
                                initialPrompt: creation.initialPrompt
                            )
                        )
                    )
                    return .none

                case let .workspaces(.workspaceCreated(creation)):
                    state.path.append(
                        .workspaceChat(
                            WorkspaceChat.State(
                                workspaceWithRepository: creation.workspace,
                                selectedModel: creation.selectedModel,
                                shouldFocusMessageField: true
                            )
                        )
                    )
                    return .none

                case let .workspaces(.workspaceTapped(item)):
                    if let cloudItem = state.workspaces.cloudCatalog.workspaces.first(
                        where: { $0.id == item.id }
                    ) {
                        state.path.append(
                            .cloudWorkspace(
                                CloudWorkspaceFeature.State(
                                    workspaceID: cloudItem.id,
                                    fallbackTitle: cloudItem.workspace.name
                                )
                            )
                        )
                    } else if item.workspace.isCloudHosted {
                        state.path.append(
                            .cloudWorkspace(
                                CloudWorkspaceFeature.State(
                                    workspaceID: item.id,
                                    fallbackTitle: item.workspace.displayName
                                )
                            )
                        )
                    } else {
                        state.path.append(
                            .workspaceChat(
                                WorkspaceChat.State(workspaceWithRepository: item)
                            )
                        )
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
            case let .cloudWorkspace(store):
                CloudWorkspaceView(store: store)

            case let .workspaceChat(store):
                WorkspaceChatView(store: store)
            }
        }
        .task {
            // MainView stays mounted while destinations are pushed, keeping the workspace socket
            // alive while the root WorkspacesView is off-screen.
            await store.send(.workspaces(.task)).finish()
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
