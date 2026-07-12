import ComposableArchitecture
import ConductorData
import ConductorDesign
import Foundation
import SQLiteData
import SwiftUI

@Reducer
public struct ArchivedSessions: Sendable {
    @ObservableState
    public struct State: Equatable {
        @FetchAll public var sessions: [Session]

        public init(workspaceID: String, sessions: [Session]) {
            self._sessions = FetchAll(
                wrappedValue: sessions,
                Session
                    .where { $0.workspaceID.eq(workspaceID).and($0.isHidden) }
                    .order { $0.updatedAt.desc() },
                animation: .default
            )
        }
    }

    public enum Action { }

    public init() { }

    public var body: some ReducerOf<Self> {
        EmptyReducer()
    }
}

struct ArchivedSessionsView: View {
    @Environment(\.dismiss) private var dismiss
    let store: StoreOf<ArchivedSessions>

    var body: some View {
        NavigationStack {
            List(store.sessions) { session in
                ArchivedSessionRow(session: session)
                    .listRowBackground(Color.theme(.background))
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(.theme(.background))
            .themedNavigationTitle("Archived Sessions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) {
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private struct ArchivedSessionRow: View {
        let session: Session
        var body: some View {
            LabeledContent {
                if let updatedDate = session.updatedDate {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsedTime = context.date.timeIntervalSince(updatedDate)

                        Text(
                            updatedDate,
                            format: .relative(presentation: .numeric, unitsStyle: .narrow)
                        )
                            .font(.theme(.body))
                            .foregroundStyle(.theme(.textSecondary))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .contentTransition(.numericText(value: elapsedTime))
                            .animation(.default, value: elapsedTime)
                    }
                }
            } label: {
                Label {
                    Text(session.displayTitle)
                        .font(.theme(.body))
                        .foregroundStyle(.theme(.textPrimary))
                        .lineLimit(1)
                } icon: {
                    AgentIcon(agentType: session.agentType, size: 20, relativeTo: .body)
                }
            }
            .labelStyle(.conductorStandard)
            .labeledContentStyle(.conductorStandard)
        }
    }
}
