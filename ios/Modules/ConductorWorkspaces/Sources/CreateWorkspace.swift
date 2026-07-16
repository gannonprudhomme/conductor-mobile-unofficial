//
//  CreateWorkspace.swift
//  ConductorWorkspaces
//
//  Created by Gannon Prudomme on 7/12/26.
//

import ComposableArchitecture
import ConductorDesign
import ConductorMobileData
import LucideIcons
import SharedConductorData
import SwiftUI

@Reducer
public struct CreateWorkspace: Sendable {
    @ObservableState
    public struct State: Equatable {
        @Presents public var alert: AlertState<Action.Alert>?
        public var isCreateAPIInFlight = false

        @Shared(.createWorkspaceMessage) public var prompt = ""

        public let repositories: [Repository]
        public var selectedRepositoryID: Repository.ID

        public init(
            repositories: [Repository],
            selectedRepositoryIDFilter: Repository.ID? = nil
        ) {
            precondition(!repositories.isEmpty, "CreateWorkspace requires a repository")
            self.repositories = repositories
            self.selectedRepositoryID = repositories
                .first { $0.id == selectedRepositoryIDFilter }?
                .id
                ?? repositories[0].id
        }
    }

    public enum Action: BindableAction {
        case alert(PresentationAction<Alert>)
        case binding(BindingAction<State>)
        case createButtonTapped
        case createWorkspaceFailed(String)
        case createWorkspaceSucceeded
        case delegate(Delegate)

        public enum Alert: Equatable {}

        public enum Delegate: Equatable {
            case workspaceCreated
        }
    }

    @Dependency(\.desktopClient) var desktopClient

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .createButtonTapped:
                guard !state.isCreateAPIInFlight else {
                    return .none
                }

                state.isCreateAPIInFlight = true
                let repositoryID = state.selectedRepositoryID
                return .run { [repositoryID, prompt = state.prompt] send in
                    do {
                        try await desktopClient.createWorkspace(
                            repositoryID: repositoryID,
                            prompt: prompt
                        )
                        await send(.createWorkspaceSucceeded)
                    } catch {
                        await send(.createWorkspaceFailed(error.localizedDescription))
                    }
                }

            case let .createWorkspaceFailed(message):
                state.alert = .failedToCreateWorkspace(message: message)
                state.isCreateAPIInFlight = false
                return .none

            case .createWorkspaceSucceeded:
                state.isCreateAPIInFlight = false
                return .send(.delegate(.workspaceCreated))

            case .alert, .binding, .delegate:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }
}

extension AlertState where Action == CreateWorkspace.Action.Alert {
    static func failedToCreateWorkspace(message: String) -> Self {
        AlertState {
            TextState("Failed to create workspace")
        } message: {
            TextState(message)
        }
    }
}

public struct CreateWorkspaceView: View {
    @Bindable var store: StoreOf<CreateWorkspace>
    @FocusState private var isPromptFocused: Bool

    public init(store: StoreOf<CreateWorkspace>) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                repositoryMenu

                Divider()
            }

            promptEditor

            createButton
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.theme(.background))
        .alert($store.scope(state: \.alert, action: \.alert))
        .preferredColorScheme(.dark)
    }

    private var repositoryMenu: some View {
        let selectedRepositoryName = selectedRepository?.displayName ?? store.selectedRepositoryID

        return Menu {
            RepositoryPicker(
                store.repositories,
                selection: $store.selectedRepositoryID
            )
        } label: {
            Label {
                Text(verbatim: selectedRepositoryName)

                LucideIcon(Lucide.chevronDown, style: .body)
            } icon: {
                if let selectedRepository {
                    RepositoryIcon(repository: selectedRepository, size: 20, relativeTo: .body)
                }
            }
            .labelStyle(.conductorSmall)
            .foregroundStyle(.theme(.textPrimary))
            .font(.theme(.small))
        }
        .accessibilityLabel("Repository")
        .accessibilityValue(selectedRepositoryName)
    }

    private var promptEditor: some View {
        TextEditor(text: Binding(store.$prompt))
            .focused($isPromptFocused)
            .tint(.theme(.accent))
            .font(.theme(.body))
            .foregroundStyle(.theme(.textPrimary))
            .scrollContentBackground(.hidden)
            .overlay(alignment: .topLeading) {
                if store.prompt.isEmpty {
                    Text("What do you want to work on?")
                        .font(.theme(.body))
                        .foregroundStyle(.theme(.textSecondary))
                        .padding(EdgeInsets(vertical: 8, horizontal: 5))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel("Prompt")
            .task {
                isPromptFocused = true
            }
    }

    private var createButton: some View {
        Button {
            store.send(.createButtonTapped)
        } label: {
            Group {
                if store.isCreateAPIInFlight {
                    ProgressView()
                        .progressViewStyle(.network)
                        .tint(.theme(.background))
                        .frame(width: 24, height: 24)
                } else {
                    Text("Create")
                        .font(.theme(.body))
                }
            }
            .foregroundStyle(.theme(.background))
            .frame(minWidth: 72, minHeight: 44)
            .background(.theme(.foreground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(store.isCreateAPIInFlight)
        .opacity(store.isCreateAPIInFlight ? 0.5 : 1)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var selectedRepository: Repository? {
        store.repositories
            .first(where: { $0.id == store.selectedRepositoryID })
    }
}

#Preview {
    Text("")
        .sheet(isPresented: .constant(true)) {
            CreateWorkspaceView(
                store: Store(
                    initialState: CreateWorkspace.State(
                        repositories: [.preview()]
                    )
                ) {
                    CreateWorkspace()
                }
            )
            .presentationDetents([.medium])
        }
        .preferredColorScheme(.dark)
}
