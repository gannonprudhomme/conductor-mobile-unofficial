//
//  MessageDeliveryAttempt.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/29/26.
//

import Foundation
import SharedConductorData
import SQLiteData

@Table("message_delivery_attempts")
public struct MessageDeliveryAttempt: Equatable, Identifiable, Sendable {
    @Column("attempt_id", primaryKey: true)
    public let attemptID: UUID
    public var route: String
    @Column("account_id")
    public var accountID: String?
    @Column("credential_generation")
    public var credentialGeneration: UUID?
    @Column("desktop_endpoint")
    public var desktopEndpoint: String?
    @Column("cloud_delivery_state")
    public var cloudDeliveryState: String?
    @Column("canonical_workspace_id")
    public var canonicalWorkspaceID: Workspace.ID
    @Column("remote_workspace_id")
    public var remoteWorkspaceID: String?
    @Column("canonical_session_id")
    public var canonicalSessionID: Session.ID
    @Column("remote_session_id")
    public var remoteSessionID: String?
    public var content: String
    public var model: String
    @Column("is_fast_mode_enabled")
    public var isFastModeEnabled: Bool
    public var mode: String
    @Column("reasoning_effort")
    public var reasoningEffort: String?
    @Column("submitted_draft")
    public var submittedDraft: String
    @Column("previous_turn_id")
    public var previousTurnID: String?
    public var state: String
    @Column("result_detail")
    public var resultDetail: String?
    @Column("canonical_message_id")
    public var canonicalMessageID: Message.ID?
    @Column("canonical_turn_id")
    public var canonicalTurnID: String?
    @Column("dispatch_started_at")
    public var dispatchStartedAt: Date?
    @Column("result_presented_at")
    public var resultPresentedAt: Date?
    @Column("created_at")
    public var createdAt: Date
    @Column("last_transition_at")
    public var lastTransitionAt: Date
    @Column("acknowledged_at")
    public var acknowledgedAt: Date?

    public init(
        attemptID: UUID = UUID(),
        route: Route,
        accountID: String? = nil,
        credentialGeneration: UUID? = nil,
        desktopEndpoint: String? = nil,
        cloudDeliveryState: String? = nil,
        canonicalWorkspaceID: Workspace.ID,
        remoteWorkspaceID: String? = nil,
        canonicalSessionID: Session.ID,
        remoteSessionID: String? = nil,
        content: String,
        model: Session.Model,
        isFastModeEnabled: Bool,
        mode: MessageSendMode,
        reasoningEffort: Session.ReasoningEffort?,
        submittedDraft: String,
        previousTurnID: String? = nil,
        state: State = .ready,
        resultDetail: String? = nil,
        canonicalMessageID: Message.ID? = nil,
        canonicalTurnID: String? = nil,
        dispatchStartedAt: Date? = nil,
        resultPresentedAt: Date? = nil,
        createdAt: Date = Date(),
        lastTransitionAt: Date? = nil,
        acknowledgedAt: Date? = nil
    ) {
        self.attemptID = attemptID
        self.route = route.rawValue
        self.accountID = accountID
        self.credentialGeneration = credentialGeneration
        self.desktopEndpoint = desktopEndpoint
        self.cloudDeliveryState = cloudDeliveryState
        self.canonicalWorkspaceID = canonicalWorkspaceID
        self.remoteWorkspaceID = remoteWorkspaceID
        self.canonicalSessionID = canonicalSessionID
        self.remoteSessionID = remoteSessionID
        self.content = content
        self.model = model.rawValue
        self.isFastModeEnabled = isFastModeEnabled
        self.mode = mode.rawValue
        self.reasoningEffort = reasoningEffort?.rawValue
        self.submittedDraft = submittedDraft
        self.previousTurnID = previousTurnID
        self.state = state.rawValue
        self.resultDetail = resultDetail
        self.canonicalMessageID = canonicalMessageID
        self.canonicalTurnID = canonicalTurnID
        self.dispatchStartedAt = dispatchStartedAt
        self.resultPresentedAt = resultPresentedAt
        self.createdAt = createdAt
        self.lastTransitionAt = lastTransitionAt ?? createdAt
        self.acknowledgedAt = acknowledgedAt
    }

    public var id: UUID { attemptID }
    public var deliveryRoute: Route { Route(rawValue: route) }
    public var deliveryState: State { State(rawValue: state) }
    public var messageMode: MessageSendMode {
        MessageSendMode(rawValue: mode) ?? .sent
    }
    public var selectedModel: Session.Model { Session.Model(rawValue: model) }
    public var selectedReasoningEffort: Session.ReasoningEffort? {
        reasoningEffort.map(Session.ReasoningEffort.init(rawValue:))
    }

    public struct Route: Codable, Equatable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let desktop = Self(rawValue: "desktop")
        public static let cloud = Self(rawValue: "cloud")
    }

    public struct State: Codable, Equatable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let ready = Self(rawValue: "ready")
        public static let dispatching = Self(rawValue: "dispatching")
        public static let accepted = Self(rawValue: "accepted")
        public static let rejected = Self(rawValue: "rejected")
        public static let unknown = Self(rawValue: "unknown")
        public static let acknowledged = Self(rawValue: "acknowledged")

        public func canTransition(to destination: Self) -> Bool {
            switch (self, destination) {
            case (.ready, .dispatching),
                 (.ready, .rejected),
                 (.dispatching, .accepted),
                 (.dispatching, .rejected),
                 (.dispatching, .unknown),
                 (.dispatching, .acknowledged),
                 (.accepted, .acknowledged),
                 (.rejected, .acknowledged),
                 (.unknown, .acknowledged):
                true

            default:
                self == destination
            }
        }
    }
}

public extension MessageDeliveryAttempt {
    static func compareAndSetState(
        attemptID: UUID,
        from expectedState: State,
        to destinationState: State,
        detail: String? = nil,
        cloudDeliveryState: String? = nil,
        canonicalMessageID: Message.ID? = nil,
        canonicalTurnID: String? = nil,
        at date: Date,
        in database: Database
    ) throws -> Bool {
        guard expectedState.canTransition(to: destinationState),
              let attempt = try find(attemptID).fetchOne(database),
              attempt.deliveryState == expectedState else {
            return false
        }
        try find(attemptID)
            .update {
                $0.state = #bind(destinationState.rawValue)
                $0.resultDetail = #bind(detail ?? attempt.resultDetail)
                $0.cloudDeliveryState = #bind(
                    cloudDeliveryState ?? attempt.cloudDeliveryState
                )
                $0.canonicalMessageID = #bind(
                    canonicalMessageID ?? attempt.canonicalMessageID
                )
                $0.canonicalTurnID = #bind(
                    canonicalTurnID ?? attempt.canonicalTurnID
                )
                $0.lastTransitionAt = #bind(date)
                $0.acknowledgedAt = #bind(
                    destinationState == .acknowledged
                        ? date
                        : attempt.acknowledgedAt
                )
            }
            .execute(database)
        return true
    }

    static func claim(
        attemptID: UUID,
        at date: Date,
        in database: Database
    ) throws -> Bool {
        guard let attempt = try find(attemptID).fetchOne(database),
              attempt.deliveryState == .ready,
              attempt.dispatchStartedAt == nil else {
            return false
        }
        try find(attemptID)
            .update {
                $0.state = #bind(State.dispatching.rawValue)
                $0.dispatchStartedAt = #bind(date)
                $0.lastTransitionAt = #bind(date)
            }
            .execute(database)
        return true
    }

    static func acknowledge(
        attemptID: UUID,
        canonicalMessageID: Message.ID?,
        canonicalTurnID: String?,
        at date: Date,
        in database: Database
    ) throws -> Bool {
        guard let attempt = try find(attemptID).fetchOne(database) else {
            return false
        }
        return try compareAndSetState(
            attemptID: attemptID,
            from: attempt.deliveryState,
            to: .acknowledged,
            canonicalMessageID: canonicalMessageID,
            canonicalTurnID: canonicalTurnID,
            at: date,
            in: database
        )
    }

    static func acknowledgeDesktopMessages(
        _ messages: [Message],
        sessionID: Session.ID,
        in database: Database
    ) throws {
        let userMessages = messages.filter { $0.role == .user }
        guard !userMessages.isEmpty else {
            return
        }
        let attempts = try MessageDeliveryAttempt
            .where {
                $0.canonicalSessionID.eq(sessionID)
                    && $0.route.eq(Route.desktop.rawValue)
                    && $0.state.neq(State.acknowledged.rawValue)
            }
            .fetchAll(database)
        for attempt in attempts where attempt.messageMode == .sent {
            let attemptID = attempt.attemptID.uuidString.lowercased()
            guard let message = userMessages.first(where: {
                $0.id == attempt.canonicalMessageID
                    || $0.sdkMessageID?.lowercased() == attemptID
                    || $0.turnID?.lowercased() == attemptID
            }) else {
                continue
            }
            _ = try acknowledge(
                attemptID: attempt.attemptID,
                canonicalMessageID: message.id,
                canonicalTurnID: message.turnID,
                at: Date(),
                in: database
            )
        }
    }
}
