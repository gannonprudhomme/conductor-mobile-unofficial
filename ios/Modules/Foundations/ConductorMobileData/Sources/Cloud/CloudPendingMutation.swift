//
//  CloudPendingMutation.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/28/26.
//

import Foundation
import SQLiteData

@Table("cloud_pending_mutations")
public struct CloudPendingMutation: Equatable, Identifiable, Sendable {
    @Column("attempt_id", primaryKey: true)
    public let attemptID: UUID
    @Column("account_id")
    public var accountID: String
    @Column("credential_generation")
    public var credentialGeneration: UUID
    public var operation: String
    @Column("resource_kind")
    public var resourceKind: String
    @Column("request_version")
    public var requestVersion: Int
    @Column("request_payload")
    public var requestPayload: Data
    @Column("rollback_payload")
    public var rollbackPayload: Data?
    @Column("canonical_workspace_id")
    public var canonicalWorkspaceID: String?
    @Column("remote_workspace_id")
    public var remoteWorkspaceID: String?
    @Column("canonical_session_id")
    public var canonicalSessionID: String?
    @Column("remote_session_id")
    public var remoteSessionID: String?
    @Column("canonical_message_id")
    public var canonicalMessageID: String?
    @Column("stable_remote_message_id")
    public var stableRemoteMessageID: String?
    public var state: String
    @Column("dispatch_started_at")
    public var dispatchStartedAt: Date?
    @Column("created_at")
    public var createdAt: Date
    @Column("last_transition_at")
    public var lastTransitionAt: Date

    public init<Request: Encodable>(
        attemptID: UUID = UUID(),
        accountID: String,
        credentialGeneration: UUID,
        operation: Operation,
        resourceKind: ResourceKind,
        requestVersion: Int = 1,
        request: Request,
        rollbackPayload: Data? = nil,
        canonicalWorkspaceID: String? = nil,
        remoteWorkspaceID: String? = nil,
        canonicalSessionID: String? = nil,
        remoteSessionID: String? = nil,
        canonicalMessageID: String? = nil,
        stableRemoteMessageID: String? = nil,
        state: State = .submitting,
        dispatchStartedAt: Date? = nil,
        createdAt: Date = Date(),
        lastTransitionAt: Date? = nil
    ) throws {
        self.attemptID = attemptID
        self.accountID = accountID
        self.credentialGeneration = credentialGeneration
        self.operation = operation.rawValue
        self.resourceKind = resourceKind.rawValue
        self.requestVersion = requestVersion
        self.requestPayload = try JSONEncoder.cloudMutation.encode(request)
        self.rollbackPayload = rollbackPayload
        self.canonicalWorkspaceID = canonicalWorkspaceID
        self.remoteWorkspaceID = remoteWorkspaceID
        self.canonicalSessionID = canonicalSessionID
        self.remoteSessionID = remoteSessionID
        self.canonicalMessageID = canonicalMessageID
        self.stableRemoteMessageID = stableRemoteMessageID
        self.state = state.rawValue
        self.dispatchStartedAt = dispatchStartedAt
        self.createdAt = createdAt
        self.lastTransitionAt = lastTransitionAt ?? createdAt
    }

    public var id: UUID { attemptID }
    public var mutationOperation: Operation {
        Operation(rawValue: operation)
    }
    public var mutationState: State {
        State(rawValue: state)
    }

    public func request<Request: Decodable>(
        as _: Request.Type
    ) throws -> Request {
        try JSONDecoder.cloudMutation.decode(
            Request.self,
            from: requestPayload
        )
    }

    public func rollback<Rollback: Decodable>(
        as _: Rollback.Type
    ) throws -> Rollback? {
        guard let rollbackPayload else {
            return nil
        }
        return try JSONDecoder.cloudMutation.decode(
            Rollback.self,
            from: rollbackPayload
        )
    }

    public struct Operation: Codable, Equatable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let cancelSession = Self(rawValue: "cancel-session")
        public static let createSession = Self(rawValue: "create-session")
        public static let renameSession = Self(rawValue: "rename-session")
        public static let archiveSession = Self(rawValue: "archive-session")
        public static let createWorkspace = Self(rawValue: "create-workspace")
        public static let renameWorkspace = Self(rawValue: "rename-workspace")
        public static let archiveWorkspace = Self(rawValue: "archive-workspace")
    }

    public struct ResourceKind: Codable, Equatable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let message = Self(rawValue: "message")
        public static let session = Self(rawValue: "session")
        public static let workspace = Self(rawValue: "workspace")
    }

    public struct State: Codable, Equatable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let submitting = Self(rawValue: "submitting")
        public static let indeterminate = Self(rawValue: "indeterminate")
        public static let accepted = Self(rawValue: "accepted")
        public static let acknowledged = Self(rawValue: "acknowledged")

        public func canTransition(to destination: Self) -> Bool {
            switch (self, destination) {
            case (.submitting, .indeterminate),
                 (.submitting, .accepted),
                 (.submitting, .acknowledged),
                 (.indeterminate, .accepted),
                 (.indeterminate, .acknowledged),
                 (.accepted, .acknowledged):
                true

            default:
                self == destination
            }
        }
    }
}

public extension CloudPendingMutation {
    static func compareAndSetState(
        attemptID: UUID,
        from expectedState: State,
        to destinationState: State,
        at date: Date,
        in database: Database
    ) throws -> Bool {
        guard expectedState.canTransition(to: destinationState),
              let attempt = try find(attemptID).fetchOne(database),
              attempt.mutationState == expectedState else {
            return false
        }
        try find(attemptID)
            .update {
                $0.state = #bind(destinationState.rawValue)
                $0.lastTransitionAt = #bind(date)
            }
            .execute(database)
        return true
    }

    static func markDispatchStarted(
        attemptID: UUID,
        at date: Date,
        in database: Database
    ) throws -> Bool {
        guard let attempt = try find(attemptID).fetchOne(database),
              attempt.mutationState == .submitting,
              attempt.dispatchStartedAt == nil else {
            return false
        }
        try find(attemptID)
            .update {
                $0.dispatchStartedAt = #bind(date)
                $0.lastTransitionAt = #bind(date)
            }
            .execute(database)
        return true
    }
}

extension JSONEncoder {
    public static var cloudMutation: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    public static var cloudMutation: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
