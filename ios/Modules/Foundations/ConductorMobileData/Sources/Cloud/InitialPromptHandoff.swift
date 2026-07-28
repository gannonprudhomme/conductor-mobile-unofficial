//
//  InitialPromptHandoff.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/28/26.
//

import Foundation
import SQLiteData

@Table("initial_prompt_handoffs")
public struct InitialPromptHandoff: Equatable, Identifiable, Sendable {
    @Column("handoff_id", primaryKey: true)
    public let handoffID: UUID
    @Column("creation_attempt_id")
    public var creationAttemptID: UUID
    @Column("account_id")
    public var accountID: String
    @Column("credential_generation")
    public var credentialGeneration: UUID
    @Column("canonical_workspace_id")
    public var canonicalWorkspaceID: String
    @Column("remote_workspace_id")
    public var remoteWorkspaceID: String
    @Column("canonical_session_id")
    public var canonicalSessionID: String
    @Column("remote_session_id")
    public var remoteSessionID: String
    @Column("original_prompt")
    public var originalPrompt: String
    @Column("stable_remote_message_id")
    public var stableRemoteMessageID: String
    @Column("send_attempt_id")
    public var sendAttemptID: UUID?
    @Column("installed_draft_text")
    public var installedDraftText: String?
    public var state: String
    @Column("created_at")
    public var createdAt: Date
    @Column("last_transition_at")
    public var lastTransitionAt: Date

    public init(
        handoffID: UUID = UUID(),
        creationAttemptID: UUID,
        accountID: String,
        credentialGeneration: UUID,
        canonicalWorkspaceID: String,
        remoteWorkspaceID: String,
        canonicalSessionID: String,
        remoteSessionID: String,
        originalPrompt: String,
        stableRemoteMessageID: String = UUID().uuidString,
        sendAttemptID: UUID? = nil,
        installedDraftText: String? = nil,
        state: State = .ready,
        createdAt: Date = Date(),
        lastTransitionAt: Date? = nil
    ) {
        self.handoffID = handoffID
        self.creationAttemptID = creationAttemptID
        self.accountID = accountID
        self.credentialGeneration = credentialGeneration
        self.canonicalWorkspaceID = canonicalWorkspaceID
        self.remoteWorkspaceID = remoteWorkspaceID
        self.canonicalSessionID = canonicalSessionID
        self.remoteSessionID = remoteSessionID
        self.originalPrompt = originalPrompt
        self.stableRemoteMessageID = stableRemoteMessageID
        self.sendAttemptID = sendAttemptID
        self.installedDraftText = installedDraftText
        self.state = state.rawValue
        self.createdAt = createdAt
        self.lastTransitionAt = lastTransitionAt ?? createdAt
    }

    public var id: UUID { handoffID }
    public var handoffState: State { State(rawValue: state) }

    public struct State: Codable, Equatable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let ready = Self(rawValue: "ready")
        public static let linked = Self(rawValue: "linked")
        public static let manual = Self(rawValue: "manual")
        public static let resolved = Self(rawValue: "resolved")
    }
}
