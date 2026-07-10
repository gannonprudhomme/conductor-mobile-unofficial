import ComposableArchitecture
import ConductorChat
import ConductorSessions
import ConductorWorkspaces
import SwiftUI

@Reducer
public struct Main {
    @Reducer
    public enum Path {
        case chat(Chat)
        case sessions(SessionsList)
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
                    .sessions(
                        SessionsList.State(
                            workspace: item.workspace,
                            repository: item.repository
                        )
                    )
                )
                return .none

            case let .path(.element(id: _, action: .sessions(.sessionTapped(session)))):
                state.path.append(.chat(Chat.State(session: session)))
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
            case let .chat(store):
                ChatView(store: store)

            case let .sessions(store):
                SessionsListView(store: store)
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
