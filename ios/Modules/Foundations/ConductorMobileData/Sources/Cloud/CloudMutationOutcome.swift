//
//  CloudMutationOutcome.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/28/26.
//

import Foundation
import SQLiteData

@Table("cloud_mutation_outcomes")
public struct CloudMutationOutcome: Equatable, Identifiable, Sendable {
    @Column("outcome_id", primaryKey: true)
    public let outcomeID: UUID
    @Column("attempt_id")
    public var attemptID: UUID
    @Column("account_id")
    public var accountID: String
    @Column("credential_generation")
    public var credentialGeneration: UUID
    @Column("owning_feature")
    public var owningFeature: String
    public var kind: String
    public var version: Int
    public var payload: Data
    @Column("created_at")
    public var createdAt: Date
    @Column("consumed_at")
    public var consumedAt: Date?

    public init<Payload: Encodable>(
        outcomeID: UUID = UUID(),
        attemptID: UUID,
        accountID: String,
        credentialGeneration: UUID,
        owningFeature: OwningFeature,
        kind: Kind,
        version: Int = 1,
        payload: Payload,
        createdAt: Date = Date(),
        consumedAt: Date? = nil
    ) throws {
        self.outcomeID = outcomeID
        self.attemptID = attemptID
        self.accountID = accountID
        self.credentialGeneration = credentialGeneration
        self.owningFeature = owningFeature.rawValue
        self.kind = kind.rawValue
        self.version = version
        self.payload = try JSONEncoder.cloudMutation.encode(payload)
        self.createdAt = createdAt
        self.consumedAt = consumedAt
    }

    public var id: UUID { outcomeID }

    public func decodedPayload<Payload: Decodable>(
        as _: Payload.Type
    ) throws -> Payload {
        try JSONDecoder.cloudMutation.decode(Payload.self, from: payload)
    }

    public struct OwningFeature: Codable, Equatable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let workspaces = Self(rawValue: "workspaces")

        public static func workspaceChat(
            workspaceID: String
        ) -> Self {
            Self(rawValue: "workspace-chat:\(workspaceID)")
        }

        public static func chat(sessionID: String) -> Self {
            Self(rawValue: "chat:\(sessionID)")
        }
    }

    public struct Kind: Codable, Equatable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let workspaceCreationCompleted =
            Self(rawValue: "workspace-creation-completed")
        public static let rejectedMutation =
            Self(rawValue: "rejected-mutation")
    }
}

public struct CloudMutationRejectionPayload: Codable, Equatable, Sendable {
    public let title: String
    public let message: String
    public let operation: String
    public let canonicalWorkspaceID: String?
    public let canonicalSessionID: String?

    public init(
        title: String,
        message: String,
        operation: String,
        canonicalWorkspaceID: String?,
        canonicalSessionID: String?
    ) {
        self.title = title
        self.message = message
        self.operation = operation
        self.canonicalWorkspaceID = canonicalWorkspaceID
        self.canonicalSessionID = canonicalSessionID
    }
}
