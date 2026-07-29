//
//  QueuedMessages.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/19/26.
//

import Combine
import ComposableArchitecture
import ConductorDesign
import ConductorMobileData
import Foundation
import LucideIcons
import SharedConductorData
import SQLiteData
import SwiftUI

enum QueuedMessagesPresentation {
    static let animationDuration: TimeInterval = 0.3
    static let disclosureAnimation: Animation = .interactiveSpring(duration: 0.3, extraBounce: 0.05) // .easeInOut(duration: animationDuration)
    static let expandedRowCount: CGFloat = 4
    static let headerHeight: CGFloat = 44
    static let horizontalPadding: CGFloat = 8
    static let listRowVerticalPadding: CGFloat = 8
    static let separatorHeight: CGFloat = 1

    static func idealHeight(
        isExpanded: Bool,
        rowHeight: CGFloat,
        numRows: Int
    ) -> CGFloat {
        guard isExpanded else {
            return headerHeight
        }

        let rowHeightWithPadding = rowHeight + listRowVerticalPadding
        let rowHeight = rowHeightWithPadding * min(CGFloat(numRows), expandedRowCount)

        return headerHeight
            + separatorHeight
            + rowHeight
    }

    static func minimumHeight(
        isExpanded: Bool,
        rowHeight: CGFloat,
        numRows: Int
    ) -> CGFloat {
        guard isExpanded, numRows > 0 else {
            return headerHeight
        }

        return headerHeight
            + separatorHeight
            + rowHeight
            + listRowVerticalPadding
    }
}

@Reducer
public struct QueuedMessages: Sendable {
    @ObservableState
    public struct State: Equatable {
        @FetchAll var messages: [Message]
        @FetchOne var session: Session
        var editStartInFlightMessageID: Message.ID?
        var editingMessageID: Message.ID?
        var editDraft = ""
        var isEditInFlight = false
        var isExpanded = false
        var messageActionInFlightID: Message.ID?
        var isReorderInFlight = false
        var isResumeInFlight = false
        var mutationRoute: WorkspaceMutationRoute?
        var pendingMessageIDs: [Message.ID]?
        var shouldResumeAfterEditing = false

        var displayedMessages: [Message] {
            guard let pendingMessageIDs,
                  Set(pendingMessageIDs) == Set(messages.map(\.id)) else {
                return messages
            }

            let messagesByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
            return pendingMessageIDs.compactMap { messagesByID[$0] }
        }

        var shouldShowResumeButton: Bool {
            session.queuePausedAt != nil
        }

        var isEditing: Bool {
            editingMessageID != nil
        }

        var isEditStartInFlight: Bool {
            editStartInFlightMessageID != nil
        }

        var isInteractionEnabled: Bool {
            !isEditStartInFlight
                && !isEditing
                && messageActionInFlightID == nil
                && !isReorderInFlight
                && !isResumeInFlight
        }

        var menuActionInFlightMessageID: Message.ID? {
            editStartInFlightMessageID ?? messageActionInFlightID
        }

        var sessionID: Session.ID {
            session.id
        }

        init(
            session: Session,
            mutationRoute: WorkspaceMutationRoute? = .desktop
        ) {
            self.mutationRoute = mutationRoute
            self._session = FetchOne(
                wrappedValue: session,
                Session.find(session.id),
                animation: .default
            )
            self._messages = FetchAll(
                wrappedValue: [],
                Message
                    .where {
                        $0.sessionID.eq(session.id)
                            && $0.sentAt.is(nil)
                            && $0.queueOrder.isNot(nil)
                            && $0.cancelledAt.is(nil)
                    }
                    .order {
                        (
                            $0.queueOrder.asc(nulls: .last),
                            $0.createdAt,
                            $0.id
                        )
                    },
                animation: .default
            )
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case task
        case messagesUpdated([Message])
        case disclosureButtonTapped
        case deleteButtonTapped(Message.ID)
        case deleteResponse(
            sessionID: Session.ID,
            messageID: Message.ID,
            result: Result<Void, any Error>
        )
        case messageTapped(Message.ID)
        case beginEditResponse(
            sessionID: Session.ID,
            messageID: Message.ID,
            result: Result<DesktopClient.QueuedMessageEdit, any Error>
        )
        case cancelEditButtonTapped
        case cancelEditResponse(
            sessionID: Session.ID,
            result: Result<Void, any Error>
        )
        case finishEditButtonTapped
        case finishEditResponse(
            sessionID: Session.ID,
            messageID: Message.ID,
            result: Result<Void, any Error>
        )
        case messagesReordered([Message.ID])
        case reorderResponse(
            sessionID: Session.ID,
            result: Result<Void, any Error>
        )
        case resumeButtonTapped
        case resumeResponse(
            sessionID: Session.ID,
            result: Result<Void, any Error>
        )
        case steerButtonTapped(Message.ID)
        case steerResponse(
            sessionID: Session.ID,
            messageID: Message.ID,
            result: Result<Void, any Error>
        )
    }

    @Dependency(\.desktopClient) var desktopClient

    public init() { }

    public var body: some ReducerOf<Self> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .task:
                return observeMessages(state)

            case let .messagesUpdated(messages):
                if let pendingMessageIDs = state.pendingMessageIDs {
                    let messageIDs = messages.map(\.id)
                    if pendingMessageIDs == messageIDs
                        || Set(pendingMessageIDs) != Set(messageIDs) {
                        state.pendingMessageIDs = nil
                    }
                }
                return .none

            case .disclosureButtonTapped:
                state.isExpanded.toggle()
                return .none

            case let .deleteButtonTapped(messageID):
                guard state.isInteractionEnabled,
                      state.messages.contains(where: { $0.id == messageID }) else {
                    return .none
                }

                state.messageActionInFlightID = messageID
                return .run {
                    [
                        sessionID = state.session.id,
                        workspaceID = state.session.workspaceID,
                    ] send in
                    await send(
                        .deleteResponse(
                            sessionID: sessionID,
                            messageID: messageID,
                            result: await Result {
                                try await desktopClient.deleteQueuedMessage(
                                    workspaceID: workspaceID,
                                    sessionID: sessionID,
                                    messageID: messageID
                                )
                            }
                        )
                    )
                }

            case let .deleteResponse(sessionID, messageID, _):
                guard sessionID == state.sessionID,
                      messageID == state.messageActionInFlightID else {
                    return .none
                }

                state.messageActionInFlightID = nil
                return .none

            case let .messageTapped(messageID):
                guard state.isInteractionEnabled,
                      state.messages.contains(where: { $0.id == messageID }) else {
                    return .none
                }

                state.editStartInFlightMessageID = messageID
                return .run {
                    [
                        sessionID = state.session.id,
                        workspaceID = state.session.workspaceID,
                    ] send in
                    await send(
                        .beginEditResponse(
                            sessionID: sessionID,
                            messageID: messageID,
                            result: await Result {
                                try await desktopClient.beginQueuedMessageEdit(
                                    workspaceID: workspaceID,
                                    sessionID: sessionID,
                                    messageID: messageID
                                )
                            }
                        )
                    )
                }

            case let .beginEditResponse(sessionID, messageID, result):
                guard sessionID == state.sessionID,
                      messageID == state.editStartInFlightMessageID else {
                    return .none
                }

                state.editStartInFlightMessageID = nil
                guard case let .success(edit) = result,
                      edit.message.id == messageID,
                      edit.message.sessionID == sessionID else {
                    return .none
                }

                state.editingMessageID = messageID
                state.editDraft = edit.message.content ?? ""
                state.shouldResumeAfterEditing = edit.shouldResumeQueue
                return .none

            case .cancelEditButtonTapped:
                guard state.isEditing,
                      !state.isEditInFlight else {
                    return .none
                }

                guard state.shouldResumeAfterEditing else {
                    clearEdit(state: &state)
                    return .none
                }

                state.isEditInFlight = true
                return .run {
                    [
                        sessionID = state.session.id,
                        workspaceID = state.session.workspaceID,
                    ] send in
                    await send(
                        .cancelEditResponse(
                            sessionID: sessionID,
                            result: await Result {
                                try await desktopClient.resumeQueuedMessages(
                                    workspaceID: workspaceID,
                                    sessionID: sessionID
                                )
                            }
                        )
                    )
                }

            case let .cancelEditResponse(sessionID, result):
                guard sessionID == state.sessionID else {
                    return .none
                }

                state.isEditInFlight = false
                if case .success = result {
                    clearEdit(state: &state)
                }
                return .none

            case .finishEditButtonTapped:
                guard let messageID = state.editingMessageID else {
                    return .none
                }

                let content = state.editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty,
                      !state.isEditInFlight else {
                    return .none
                }

                state.isEditInFlight = true
                return .run {
                    [
                        sessionID = state.session.id,
                        shouldResumeQueue = state.shouldResumeAfterEditing,
                        workspaceID = state.session.workspaceID,
                    ] send in
                    await send(
                        .finishEditResponse(
                            sessionID: sessionID,
                            messageID: messageID,
                            result: await Result {
                                try await desktopClient.finishQueuedMessageEdit(
                                    workspaceID: workspaceID,
                                    sessionID: sessionID,
                                    messageID: messageID,
                                    content: content,
                                    shouldResumeQueue: shouldResumeQueue
                                )
                            }
                        )
                    )
                }

            case let .finishEditResponse(sessionID, messageID, result):
                guard sessionID == state.sessionID,
                      messageID == state.editingMessageID else {
                    return .none
                }

                state.isEditInFlight = false
                if case .success = result {
                    clearEdit(state: &state)
                }
                return .none

            case let .messagesReordered(messageIDs):
                let currentMessageIDs = state.messages.map(\.id)
                guard state.isInteractionEnabled,
                      messageIDs != currentMessageIDs,
                      messageIDs.count == currentMessageIDs.count,
                      Set(messageIDs) == Set(currentMessageIDs) else {
                    return .none
                }

                state.pendingMessageIDs = messageIDs
                state.isReorderInFlight = true
                return .run {
                    [
                        sessionID = state.session.id,
                        workspaceID = state.session.workspaceID,
                    ] send in
                    await send(
                        .reorderResponse(
                            sessionID: sessionID,
                            result: await Result {
                                try await desktopClient.reorderQueuedMessages(
                                    workspaceID: workspaceID,
                                    sessionID: sessionID,
                                    messageIDs: messageIDs
                                )
                            }
                        )
                    )
                }

            case let .reorderResponse(sessionID, result):
                guard sessionID == state.sessionID else {
                    return .none
                }

                state.isReorderInFlight = false
                if case .failure = result {
                    state.pendingMessageIDs = nil
                }
                return .none

            case .resumeButtonTapped:
                guard state.shouldShowResumeButton,
                      state.isInteractionEnabled,
                      !state.isEditInFlight else {
                    return .none
                }

                state.isResumeInFlight = true
                return .run {
                    [
                        sessionID = state.session.id,
                        workspaceID = state.session.workspaceID,
                    ] send in
                    await send(
                        .resumeResponse(
                            sessionID: sessionID,
                            result: await Result {
                                try await desktopClient.resumeQueuedMessages(
                                    workspaceID: workspaceID,
                                    sessionID: sessionID
                                )
                            }
                        )
                    )
                }

            case let .resumeResponse(sessionID, _):
                guard sessionID == state.sessionID else {
                    return .none
                }

                state.isResumeInFlight = false
                return .none

            case let .steerButtonTapped(messageID):
                guard state.isInteractionEnabled,
                      state.messages.contains(where: { $0.id == messageID }) else {
                    return .none
                }

                state.messageActionInFlightID = messageID
                return .run {
                    [
                        sessionID = state.session.id,
                        workspaceID = state.session.workspaceID,
                    ] send in
                    await send(
                        .steerResponse(
                            sessionID: sessionID,
                            messageID: messageID,
                            result: await Result {
                                try await desktopClient.steerQueuedMessage(
                                    workspaceID: workspaceID,
                                    sessionID: sessionID,
                                    messageID: messageID
                                )
                            }
                        )
                    )
                }

            case let .steerResponse(sessionID, messageID, _):
                guard sessionID == state.sessionID,
                      messageID == state.messageActionInFlightID else {
                    return .none
                }

                state.messageActionInFlightID = nil
                return .none

            case .binding:
                return .none
            }
        }
    }

    private func clearEdit(state: inout State) {
        state.editingMessageID = nil
        state.editDraft = ""
        state.shouldResumeAfterEditing = false
    }

    private func observeMessages(_ state: State) -> Effect<Action> {
        .publisher {
            state.$messages.publisher
                .removeDuplicates()
                .map(Action.messagesUpdated)
        }
    }
}

struct QueuedMessagesView: View {
    @Bindable var store: StoreOf<QueuedMessages>
    let firstRowFrameChanged: @MainActor (CGRect) -> Void

    @ScaledMetric(relativeTo: ThemeFontStyle.body.textStyle)
    private var rowHeight: CGFloat = 44

    init(
        store: StoreOf<QueuedMessages>,
        firstRowFrameChanged: @escaping @MainActor (CGRect) -> Void = { _ in }
    ) {
        self.store = store
        self.firstRowFrameChanged = firstRowFrameChanged
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                toggleDisclosure()
            } label: {
                header
            }
            .disabled(store.isEditing)

            if store.isExpanded {
                expandedContent
                    .transition(expandedContentTransition)
            }
        }
        .animation(.default, value: store.messages)
        .clipShape(.rect(cornerRadius: 26))
        .glassEffect(
            .clear.tint(.theme(.background).opacity(0.925)),
            in: .rect(cornerRadius: 26)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 26)
                .stroke(.theme(.border))
        }
        .padding(.horizontal, QueuedMessagesPresentation.horizontalPadding)
        .sensoryFeedback(.selection, trigger: store.isExpanded)
        .task {
            await store.send(.task).finish()
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(.theme(.border))
                .frame(height: QueuedMessagesPresentation.separatorHeight)

            messageList
                .frame(
                    minHeight: minimumMessageListHeight,
                    idealHeight: idealMessageListHeight,
                    maxHeight: idealMessageListHeight
                )
        }
    }

    private var expandedContentTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(
                .easeIn(duration: 0.15).delay(0.15)
            ),
            removal: .opacity.animation(
                .easeOut(duration: 0.1)
            )
        )
    }

    private var idealMessageListHeight: CGFloat {
        let mainHeight = QueuedMessagesPresentation.idealHeight(
            isExpanded: true,
            rowHeight: rowHeight,
            numRows: store.displayedMessages.count
        )

        return mainHeight
            - QueuedMessagesPresentation.headerHeight
            - QueuedMessagesPresentation.separatorHeight
    }

    private var minimumMessageListHeight: CGFloat {
        let minimumHeight = QueuedMessagesPresentation.minimumHeight(
            isExpanded: true,
            rowHeight: rowHeight,
            numRows: store.displayedMessages.count
        )

        return max(
            0,
            minimumHeight
                - QueuedMessagesPresentation.headerHeight
                - QueuedMessagesPresentation.separatorHeight
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(title)
                    .contentTransition(.interpolate)

                Text("(\(store.messages.count))")
                    .font(.theme(.extraExtraSmall))
                    .foregroundStyle(.theme(.textSecondary))
                    .contentTransition(
                        .numericText(value: Double(store.messages.count))
                    )
            }
            .lineLimit(1)
            .font(.theme(.small))
            .foregroundStyle(.theme(.textPrimary))
            .contentShape(.rect)
            .frame(
                maxWidth: store.isExpanded ? .infinity : nil,
                alignment: .leading
            )
            .accessibilityLabel(store.isExpanded ? "Collapse queue" : "Expand queue")

            if store.shouldShowResumeButton {
                resumeButton
            }

            LucideIcon(Lucide.chevronRight, style: .body)
                .foregroundStyle(.theme(.sidebarMutedForeground))
                .rotationEffect(.degrees(store.isExpanded ? 90 : 0))
                .animation(
                    QueuedMessagesPresentation.disclosureAnimation,
                    value: store.isExpanded
                )
                .contentShape(.rect)
                .accessibilityLabel(store.isExpanded ? "Collapse queue" : "Expand queue")
        }
        .frame(minHeight: QueuedMessagesPresentation.headerHeight)
        .padding(.leading, 12)
        .padding(.trailing, 8)
    }

    private var resumeButton: some View {
        Button {
            store.send(.resumeButtonTapped)
        } label: {
            HStack(spacing: 6) {
                if store.isResumeInFlight {
                    ProgressView()
                        .progressViewStyle(.network)
                        .tint(.theme(.textPrimary))
                        .controlSize(.mini)
                } else {
                    LucideIcon(Lucide.play, style: .extraSmall)
                }

                if store.isExpanded {
                    Text("Resume")
                        .transition(
                            .opacity.combined(
                                with: .scale(scale: 0.8, anchor: .leading)
                            )
                        )
                }
            }
            .font(.theme(.small))
            .foregroundStyle(.theme(.textPrimary))
            .padding(
                EdgeInsets(
                    vertical: 5,
                    horizontal: store.isExpanded ? 10 : 6
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.theme(.accent))
            }
        }
        .buttonStyle(.spring)
        .disabled(!store.isInteractionEnabled)
        .opacity(store.isInteractionEnabled ? 1 : 0.5)
        .transition(.opacity)
    }

    private var title: String {
        if store.shouldShowResumeButton {
            "Queue paused"
        } else {
            "Queue"
        }
    }

    private var messageList: some View {
        List {
            ForEach(store.displayedMessages) { message in
                let isEditing = store.editingMessageID == message.id
                let menuActionInFlightMessageID =
                    store.menuActionInFlightMessageID
                let isMenuActionInFlight =
                    menuActionInFlightMessageID == message.id
                let isMenuActionDimmed =
                    menuActionInFlightMessageID != nil
                        && !isMenuActionInFlight

                QueuedMessageRow(
                    message: message,
                    isDimmed: store.isEditing && !isEditing,
                    isEditing: isEditing,
                    isFinishEditEnabled: isEditing
                        && !store.editDraft
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                        && !store.isEditInFlight,
                    isInteractionEnabled: store.isInteractionEnabled,
                    isMenuActionDimmed: isMenuActionDimmed,
                    isMenuActionInFlight: isMenuActionInFlight,
                    delete: { store.send(.deleteButtonTapped(message.id)) },
                    edit: { store.send(.messageTapped(message.id)) },
                    finishEdit: { store.send(.finishEditButtonTapped) },
                    steer: { store.send(.steerButtonTapped(message.id)) }
                )
                .frame(height: rowHeight)
                .accessibilityIdentifier("chat.queue.message.\(message.id)")
                .onGeometryChange(for: CGRect.self) { geometry in
                    geometry.frame(in: .global)
                } action: { frame in
                    if message.id == store.displayedMessages.first?.id {
                        firstRowFrameChanged(frame)
                    }
                }
                .listRowInsets(
                    EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 8)
                )
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(.theme(.border))
                .moveDisabled(!store.isInteractionEnabled)
            }
            .onMove(perform: moveMessages)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.vertical, 0, for: .scrollContent)
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .animation(.default, value: store.displayedMessages)
    }

    @MainActor
    private func moveMessages(
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) {
        guard store.isInteractionEnabled else {
            return
        }

        var messages = store.displayedMessages
        messages.move(
            fromOffsets: source,
            toOffset: destination
        )
        store.send(.messagesReordered(messages.map(\.id)))
    }

    @MainActor
    private func toggleDisclosure() {
        store.send(
            .disclosureButtonTapped,
            animation: QueuedMessagesPresentation.disclosureAnimation
        )
    }
}

private struct QueuedMessageRow: View {
    let message: Message
    let isDimmed: Bool
    let isEditing: Bool
    let isFinishEditEnabled: Bool
    let isInteractionEnabled: Bool
    let isMenuActionDimmed: Bool
    let isMenuActionInFlight: Bool
    let delete: @MainActor () -> Void
    let edit: @MainActor () -> Void
    let finishEdit: @MainActor () -> Void
    let steer: @MainActor () -> Void

    var body: some View {
        row
            .swipeActions(
                edge: .trailing,
                allowsFullSwipe: isInteractionEnabled
            ) {
                if isInteractionEnabled {
                    deleteButton(color: .theme(.foreground))
                        .tint(.theme(.destructive))
                }
            }
    }

    private var row: some View {
        HStack(spacing: 16) {
            messageLabel
                .frame(maxWidth: .infinity, alignment: .leading)

            trailingAction
                .padding(.trailing, 8)
                .animation(.default, value: isEditing)
                .animation(.default, value: isMenuActionInFlight)
        }
        .opacity(isDimmed ? 0.5 : 1)
        .animation(.default, value: isDimmed)
    }

    private var messageLabel: some View {
        Text(message.content ?? "")
            .font(.theme(.small))
            .foregroundStyle(.theme(.textPrimary))
            .lineLimit(1)
            .contentShape(.rect)
    }

    @ViewBuilder
    private var trailingAction: some View {
        if isEditing {
            Button(action: finishEdit) {
                Label {
                    Text("Save queued message")
                } icon: {
                    LucideIcon(Lucide.check, style: .body)
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.theme(.sidebarMutedForeground))
                .frame(height: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!isFinishEditEnabled)
            .accessibilityIdentifier("chat.queue.message.\(message.id).save")
            .transition(.blurReplace.combined(with: .scale(0.8)))
        } else if isMenuActionInFlight {
            ProgressView()
                .progressViewStyle(.network)
                .tint(.theme(.sidebarMutedForeground))
                .controlSize(.mini)
                .frame(height: 44)
                .accessibilityLabel("Queued message action in progress")
                .accessibilityIdentifier(
                    "chat.queue.message.\(message.id).action-in-flight"
                )
                .transition(.blurReplace.combined(with: .scale(0.8)))
        } else {
            Menu {
                editButton

                steerButton

                deleteButton(color: .theme(.destructive))
            } label: {
                LucideIcon(Lucide.ellipsis, style: .body)
                    .foregroundStyle(.theme(.sidebarMutedForeground))
                    // width makes it take up too much space
                    .frame(height: 44)
                    // .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .disabled(!isInteractionEnabled)
            .opacity(isMenuActionDimmed ? 0.5 : 1)
            .accessibilityLabel("Queued message actions")
            .transition(.blurReplace.combined(with: .scale(0.8)))
            .animation(.default, value: isMenuActionDimmed)
        }
    }

    private var editButton: some View {
        Button(action: edit) {
            Label {
                Text("Edit")
            } icon: {
                ColoredMenuImage(Lucide.pencil)
            }
        }
    }

    private func deleteButton(color: Color) -> some View {
        Button(role: .destructive, action: delete) {
            Label {
                Text("Delete")
            } icon: {
                ColoredMenuImage(Lucide.trash2, color: color)
            }
        }
    }

    private var steerButton: some View {
        Button(action: steer) {
            Label {
                Text("Steer")
            } icon: {
                ColoredMenuImage(Lucide.arrowUp)
            }
        }
    }
}
