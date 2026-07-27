//
//  ArchivedSessions.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/12/26.
//

import ComposableArchitecture
import ConductorDesign
import ConductorMobileData
import Foundation
import LucideIcons
import SharedConductorData
import SQLiteData
import SwiftUI

@Reducer
public struct ArchivedSessions: Sendable {
    @ObservableState
    public struct State: Equatable {
        @Presents public var alert: AlertState<Action.Alert>?
        @FetchAll public var activeSessions: [Session]
        @FetchAll public var sessions: [Session]
        public var restoringSessionIDs: Set<Session.ID> = []

        public init(
            workspaceID: String,
            sessions: [Session],
            activeSessions: [Session]
        ) {
            self._activeSessions = FetchAll(
                wrappedValue: activeSessions,
                Session.where { $0.workspaceID.eq(workspaceID).and(!$0.isHidden) }
            )
            self._sessions = FetchAll(
                wrappedValue: sessions,
                Session
                    .where { $0.workspaceID.eq(workspaceID).and($0.isHidden) }
                    .order { $0.updatedAt.desc() },
                animation: .default
            )
        }

        var canRestoreMoreSessions: Bool {
            activeSessions.count + pendingRestoreCount < 5
        }

        private var pendingRestoreCount: Int {
            restoringSessionIDs.intersection(sessions.map(\.id)).count
        }
    }

    public enum Action {
        case alert(PresentationAction<Alert>)
        case restoreSessionButtonTapped(Session)
        case restoreSessionFailed(sessionID: Session.ID, any Error)
        case restoreSessionSucceeded(sessionID: Session.ID)

        public enum Alert: Equatable { }
    }

    @Dependency(\.desktopClient) var desktopClient

    public init() { }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .restoreSessionButtonTapped(session):
                guard !state.restoringSessionIDs.contains(session.id) else {
                    return .none
                }
                guard state.canRestoreMoreSessions else {
                    state.alert = .maximumTabsReached
                    return .none
                }
                state.restoringSessionIDs.insert(session.id)
                return .run { [session] send in
                    do {
                        try await desktopClient.restoreSession(
                            workspaceID: session.workspaceID,
                            sessionID: session.id
                        )
                        await send(.restoreSessionSucceeded(sessionID: session.id))
                    } catch {
                        await send(.restoreSessionFailed(sessionID: session.id, error))
                    }
                }

            case let .restoreSessionFailed(sessionID, error):
                state.restoringSessionIDs.remove(sessionID)
                state.alert = .failedToRestoreSession(message: error.localizedDescription)
                return .none

            case let .restoreSessionSucceeded(sessionID):
                state.restoringSessionIDs.remove(sessionID)
                return .none

            case .alert:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }
}

extension AlertState where Action == ArchivedSessions.Action.Alert {
    static func failedToRestoreSession(message: String) -> Self {
        AlertState {
            TextState("Failed to restore chat")
        } message: {
            TextState(message)
        }
    }

    static var maximumTabsReached: Self {
        AlertState {
            TextState("Maximum of 5 tabs allowed")
        }
    }
}

struct ArchivedSessionsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: StoreOf<ArchivedSessions>

    var body: some View {
        NavigationStack {
            List(store.sessions) { session in
                ArchivedSessionRow(
                    session: session,
                    isRestoreDisabled: store.restoringSessionIDs.contains(session.id)
                ) {
                    store.send(.restoreSessionButtonTapped(session))
                }
                .listRowBackground(Color.theme(.background))
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(.theme(.background))
            .themedNavigationTitle("Chat history")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) {
                        dismiss()
                    }
                }
            }
        }
        .alert($store.scope(state: \.alert, action: \.alert))
        .preferredColorScheme(.dark)
    }

    private struct ArchivedSessionRow: View {
        let session: Session
        let isRestoreDisabled: Bool
        let restore: @MainActor () -> Void

        var body: some View {
            LabeledContent {
                HStack(spacing: 12) {
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

                    Button {
                        restore()
                    } label: {
                        LucideIcon(Lucide.rotateCcw, style: .body)
                            .foregroundStyle(.theme(.textSecondary))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(isRestoreDisabled)
                    .accessibilityLabel("Restore chat")
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
