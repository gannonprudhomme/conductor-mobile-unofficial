import ComposableArchitecture
import SwiftUI

@Reducer
public struct Workspaces {
    @ObservableState
    public struct State {
        public init() {
        }
    }

    public enum Action {
        case task
    }

    public init() {
    }

    public var body: some ReducerOf<Self> {
        Reduce { _, action in
            switch action {
            case .task:
                return .none
            }
        }
    }
}

public struct WorkspacesView: View {
    let store: StoreOf<Workspaces>

    public init(store: StoreOf<Workspaces>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Workspaces",
                systemImage: "rectangle.stack",
                description: Text("Pair with Conductor on your Mac to see workspaces here.")
            )
            .navigationTitle("Workspaces")
        }
        .task {
            await store.send(.task).finish()
        }
    }
}

#Preview {
    WorkspacesView(
        store: Store(initialState: Workspaces.State()) {
            Workspaces()
        }
    )
}
