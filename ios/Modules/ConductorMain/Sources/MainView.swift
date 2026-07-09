import ComposableArchitecture
import ConductorWorkspaces
import SwiftUI

@Reducer
public struct Main {
    @ObservableState
    public struct State {
        public var workspaces = Workspaces.State()

        public init() {
        }
    }

    public enum Action {
        case workspaces(Workspaces.Action)
    }

    public init() {
    }

    public var body: some ReducerOf<Self> {
        Scope(state: \.workspaces, action: \.workspaces) {
            Workspaces()
        }
    }
}

public struct MainView: View {
    let store: StoreOf<Main>

    public init(store: StoreOf<Main>) {
        self.store = store
    }

    public var body: some View {
        WorkspacesView(
            store: store.scope(state: \.workspaces, action: \.workspaces)
        )
    }
}

#Preview {
    MainView(
        store: Store(initialState: Main.State()) {
            Main()
        }
    )
}
