//
//  CloudOwnershipCleanup.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/28/26.
//

import SharedConductorData
import SQLiteData

public enum CloudOwnershipCleanup {
    public enum Scope: Equatable, Sendable {
        case account(String)
        case sessions(Set<Session.ID>)
        case workspaces(Set<Workspace.ID>)
    }

    public enum Reason: Equatable, Sendable {
        case authoritativeSnapshot
        case credentialRemoval
    }

    public static func perform(
        scope: Scope,
        reason: Reason,
        in database: Database
    ) throws {
        let allWorkspaceMetadata = try CloudWorkspaceMetadata.all.fetchAll(database)
        let allSessionMetadata = try CloudSessionMetadata.all.fetchAll(database)
        let accountIDs: Set<String>
        var workspaceIDs: Set<Workspace.ID>
        var sessionIDs: Set<Session.ID>

        switch scope {
        case let .account(accountID):
            accountIDs = [accountID]
            workspaceIDs = Set(
                allWorkspaceMetadata
                    .filter { $0.accountID == accountID }
                    .map(\.workspaceID)
            )
            sessionIDs = Set(
                allSessionMetadata
                    .filter { $0.accountID == accountID }
                    .map(\.canonicalSessionID)
            )

        case let .workspaces(selectedWorkspaceIDs):
            workspaceIDs = selectedWorkspaceIDs
            accountIDs = Set(
                allWorkspaceMetadata
                    .filter { selectedWorkspaceIDs.contains($0.workspaceID) }
                    .map(\.accountID)
            )
            sessionIDs = Set(
                allSessionMetadata
                    .filter {
                        selectedWorkspaceIDs.contains($0.workspaceID)
                    }
                    .map(\.canonicalSessionID)
            )

        case let .sessions(selectedSessionIDs):
            sessionIDs = selectedSessionIDs
            let selectedMetadata = allSessionMetadata.filter {
                selectedSessionIDs.contains($0.canonicalSessionID)
            }
            workspaceIDs = []
            accountIDs = Set(selectedMetadata.map(\.accountID))
        }

        let attempts = try CloudPendingMutation.all.fetchAll(database)
        let deliveryAttempts = try MessageDeliveryAttempt.all.fetchAll(database)
        let outcomes = try CloudMutationOutcome.all.fetchAll(database)

        if reason == .authoritativeSnapshot {
            let archiveSessionIDs = Set(
                attempts.compactMap { attempt in
                    attempt.mutationOperation == .archiveSession
                        && attempt.canonicalSessionID.map(sessionIDs.contains) == true
                        ? attempt.canonicalSessionID
                        : nil
                }
            )
            let archiveWorkspaceIDs = Set(
                attempts.compactMap { attempt in
                    attempt.mutationOperation == .archiveWorkspace
                        && attempt.canonicalWorkspaceID.map(workspaceIDs.contains) == true
                        ? attempt.canonicalWorkspaceID
                        : nil
                }
            )

            sessionIDs = try Set(sessionIDs.filter { sessionID in
                if archiveSessionIDs.contains(sessionID) {
                    return true
                }
                return try !isProtected(
                    workspaceID: nil,
                    sessionID: sessionID,
                    attempts: attempts,
                    deliveryAttempts: deliveryAttempts,
                    outcomes: outcomes
                )
            })
            workspaceIDs = try Set(workspaceIDs.filter { workspaceID in
                if archiveWorkspaceIDs.contains(workspaceID) {
                    return true
                }
                return try !isProtected(
                    workspaceID: workspaceID,
                    sessionID: nil,
                    attempts: attempts,
                    deliveryAttempts: deliveryAttempts,
                    outcomes: outcomes
                )
            })
            sessionIDs.formUnion(
                allSessionMetadata
                    .filter { workspaceIDs.contains($0.workspaceID) }
                    .map(\.canonicalSessionID)
            )
        }

        let messageMetadata = try CloudMessageMetadata.all
            .fetchAll(database)
            .filter {
                sessionIDs.contains($0.canonicalSessionID)
                    || (
                        reason == .credentialRemoval
                            && accountIDs.contains($0.accountID)
                    )
            }
        for metadata in messageMetadata {
            try Message.find(metadata.canonicalMessageID)
                .delete()
                .execute(database)
        }
        for metadata in messageMetadata {
            try CloudMessageMetadata.find(metadata.canonicalMessageID)
                .delete()
                .execute(database)
        }

        for attempt in attempts
        where shouldDelete(
            accountID: attempt.accountID,
            workspaceID: attempt.canonicalWorkspaceID,
            sessionID: attempt.canonicalSessionID,
            accountIDs: accountIDs,
            workspaceIDs: workspaceIDs,
            sessionIDs: sessionIDs,
            reason: reason
        ) {
            try CloudMutationOutcome
                .where { $0.attemptID.eq(attempt.attemptID) }
                .delete()
                .execute(database)
            try CloudPendingMutation.find(attempt.attemptID)
                .delete()
                .execute(database)
        }
        for outcome in outcomes
        where reason == .credentialRemoval
            && accountIDs.contains(outcome.accountID) {
            try CloudMutationOutcome.find(outcome.outcomeID)
                .delete()
                .execute(database)
        }
        for deliveryAttempt in deliveryAttempts
        where deliveryAttempt.deliveryRoute == .cloud
            && (
                (
                    reason == .credentialRemoval
                        && deliveryAttempt.accountID.map(accountIDs.contains)
                            == true
                )
                    || workspaceIDs.contains(
                        deliveryAttempt.canonicalWorkspaceID
                    )
                    || sessionIDs.contains(
                        deliveryAttempt.canonicalSessionID
                    )
            ) {
            try MessageDeliveryAttempt.find(deliveryAttempt.attemptID)
                .delete()
                .execute(database)
        }

        for sessionID in sessionIDs {
            try CloudSessionMetadata.find(sessionID).delete().execute(database)
            try Session.find(sessionID).delete().execute(database)
        }

        for workspaceID in workspaceIDs {
            let metadata = allWorkspaceMetadata.first {
                $0.workspaceID == workspaceID
            }
            try CloudWorkspaceMetadata.find(workspaceID).delete().execute(database)
            let hasDesktopOwnership = try MobileWorkspaceState
                .find(workspaceID)
                .fetchOne(database) != nil
            let hasSessions = try Session
                .where { $0.workspaceID.eq(workspaceID) }
                .fetchCount(database) > 0
            if !hasDesktopOwnership, !hasSessions {
                try Workspace.find(workspaceID).delete().execute(database)
            } else if let metadata,
                      metadata.remoteWorkspaceID != workspaceID {
                try rekeyDesktopWorkspace(
                    from: workspaceID,
                    to: metadata.remoteWorkspaceID,
                    in: database
                )
            } else {
                // Retaining the Desktop row must not retain the Cloud source
                // classification after its Cloud ownership metadata is removed.
                let workspace = try Workspace
                    .find(workspaceID)
                    .fetchOne(database)
                if workspace?.hostingServerURL
                    == Workspace.conductorCloudHostingServerURL {
                    try Workspace
                        .find(workspaceID)
                        .update {
                            $0.hostingServerURL = #bind(nil as String?)
                        }
                        .execute(database)
                }
            }
        }

        guard reason == .credentialRemoval else {
            return
        }
        let mappings = try CloudProjectRepositoryMapping.all
            .fetchAll(database)
            .filter { accountIDs.contains($0.accountID) }
        for mapping in mappings {
            try CloudProjectRepositoryMapping.find(mapping.id)
                .delete()
                .execute(database)
            let isReferencedByWorkspace = try Workspace
                .where {
                    $0.repositoryID.eq(mapping.canonicalRepositoryID)
                }
                .fetchCount(database) > 0
            let isReferencedByMapping = try CloudProjectRepositoryMapping
                .where {
                    $0.canonicalRepositoryID.eq(
                        mapping.canonicalRepositoryID
                    )
                }
                .fetchCount(database) > 0
            if !isReferencedByWorkspace, !isReferencedByMapping {
                try Repository.find(mapping.canonicalRepositoryID)
                    .delete()
                    .execute(database)
            }
        }
    }

    private static func rekeyDesktopWorkspace(
        from canonicalWorkspaceID: Workspace.ID,
        to remoteWorkspaceID: Workspace.ID,
        in database: Database
    ) throws {
        guard let workspace = try Workspace
            .find(canonicalWorkspaceID)
            .fetchOne(database) else {
            return
        }
        try Workspace
            .upsert {
                workspace.replacingID(with: remoteWorkspaceID)
            }
            .execute(database)
        try Workspace
            .find(remoteWorkspaceID)
            .update {
                $0.hostingServerURL = #bind(nil as String?)
            }
            .execute(database)

        if let mobileState = try MobileWorkspaceState
            .find(canonicalWorkspaceID)
            .fetchOne(database) {
            try MobileWorkspaceState
                .upsert {
                    MobileWorkspaceState(
                        workspaceID: remoteWorkspaceID,
                        isWorking: mobileState.isWorking,
                        pullRequest: mobileState.pullRequestSnapshot
                    )
                }
                .execute(database)
        }
        try Session
            .where { $0.workspaceID.eq(canonicalWorkspaceID) }
            .update {
                $0.workspaceID = #bind(remoteWorkspaceID)
            }
            .execute(database)
        try MessageDeliveryAttempt
            .where {
                $0.route.eq(MessageDeliveryAttempt.Route.desktop.rawValue)
                    && $0.canonicalWorkspaceID.eq(canonicalWorkspaceID)
            }
            .update {
                $0.canonicalWorkspaceID = #bind(remoteWorkspaceID)
                $0.remoteWorkspaceID = #bind(remoteWorkspaceID)
            }
            .execute(database)
        try Workspace.find(canonicalWorkspaceID).delete().execute(database)
    }

    private static func isProtected(
        workspaceID: Workspace.ID?,
        sessionID: Session.ID?,
        attempts: [CloudPendingMutation],
        deliveryAttempts: [MessageDeliveryAttempt],
        outcomes: [CloudMutationOutcome]
    ) throws -> Bool {
        let protectingAttempts = attempts.filter { attempt in
            Self.matches(
                workspaceID: workspaceID,
                sessionID: sessionID,
                attemptWorkspaceID: attempt.canonicalWorkspaceID,
                attemptSessionID: attempt.canonicalSessionID
            )
                && attempt.mutationOperation != .archiveSession
                && attempt.mutationOperation != .archiveWorkspace
        }
        if !protectingAttempts.isEmpty {
            return true
        }
        if deliveryAttempts.contains(where: { attempt in
            attempt.deliveryRoute == .cloud
                && Self.matches(
                    workspaceID: workspaceID,
                    sessionID: sessionID,
                    attemptWorkspaceID: attempt.canonicalWorkspaceID,
                    attemptSessionID: attempt.canonicalSessionID
                )
                && attempt.deliveryState != .acknowledged
        }) {
            return true
        }
        let protectingAttemptIDs = Set(protectingAttempts.map(\.attemptID))
        return outcomes.contains {
            $0.consumedAt == nil
                && (
                    protectingAttemptIDs.contains($0.attemptID)
                        || (
                            $0.kind
                                == CloudMutationOutcome.Kind
                                    .workspaceCreationCompleted.rawValue
                                && (try? $0.decodedPayload(
                                    as: CloudWorkspaceCreationCompletionPayload.self
                                ).canonicalWorkspaceID) == workspaceID
                        )
                )
        }
    }

    private static func matches(
        workspaceID: Workspace.ID?,
        sessionID: Session.ID?,
        attemptWorkspaceID: Workspace.ID?,
        attemptSessionID: Session.ID?
    ) -> Bool {
        if let workspaceID {
            return attemptWorkspaceID == workspaceID
        }
        if let sessionID {
            return attemptSessionID == sessionID
        }
        return false
    }

    private static func shouldDelete(
        accountID: String,
        workspaceID: Workspace.ID?,
        sessionID: Session.ID?,
        accountIDs: Set<String>,
        workspaceIDs: Set<Workspace.ID>,
        sessionIDs: Set<Session.ID>,
        reason: Reason
    ) -> Bool {
        if reason == .credentialRemoval, accountIDs.contains(accountID) {
            return true
        }
        return workspaceID.map(workspaceIDs.contains) == true
            || sessionID.map(sessionIDs.contains) == true
    }
}
