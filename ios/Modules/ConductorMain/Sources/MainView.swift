import ComposableArchitecture
import ConductorChat
import ConductorWorkspaces
import SwiftUI

@Reducer
public struct Main: Sendable {
    @Reducer
    public enum Path {
        case workspaceChat(WorkspaceChat)
    }

    @ObservableState
    public struct State: Equatable {
        public var path = StackState<Path.State>()
        public var workspaces = Workspaces.State()

        public init() {
        }
    }

    public enum Action {
        case path(StackActionOf<Path>)
        case workspaces(Workspaces.Action)
    }

    public init() {
    }

    public var body: some ReducerOf<Self> {
        Scope(state: \.workspaces, action: \.workspaces) {
            Workspaces()
        }
        Reduce { state, action in
            switch action {
            case let .workspaces(.workspaceTapped(item)):
                state.path.append(
                    .workspaceChat(
                        WorkspaceChat.State(workspaceWithRepository: item)
                    )
                )
                return .none

            case .path, .workspaces:
                return .none
            }
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
        } destination: { store in
            switch store.case {
            case let .workspaceChat(store):
                WorkspaceChatView(store: store)
            }
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
