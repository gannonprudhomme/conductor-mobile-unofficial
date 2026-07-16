//
//  WorkspaceRoute.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Dependencies
import Foundation
import Hummingbird
import SharedConductorData
import SQLiteData

enum WorkspaceRoute {
    static func patch(
        request: Request,
        context: Server.RequestContext,
        database: any DatabaseWriter,
        persistenceTimeout: Duration
    ) async throws -> HTTPResponse.Status {
        @Dependency(\.workspaceUIHook) var uiHook

        let workspaceID = try context.parameters.require("workspaceID")
        let mutation: WorkspaceMutation
        do {
            mutation = try await request.decode(as: WorkspaceMutation.self, context: context)
        } catch {
            throw PlainTextResponseError(.badRequest, message: "Invalid workspace change.")
        }

        if case .status(let status) = mutation {
            guard validStatuses.contains(status) else {
                throw PlainTextResponseError(
                    .badRequest,
                    message: "Invalid workspace status: \(status)"
                )
            }
        }

        let workspaceExists = try await database.read { database in
            try Workspace.find(workspaceID).fetchOne(database) != nil
        }
        guard workspaceExists else {
            throw PlainTextResponseError(.notFound, message: "Workspace not found.")
        }

        let path: WorkspaceUIHook.DispatchPath
        // The UI hook holds one global slot through either live persistence or the fallback write.
        do {
            path = try await uiHook.dispatch(
                mutation: mutation,
                workspaceID: workspaceID,
                fallback: {
                    try await applyUIHookSQLiteFallback(
                        mutation,
                        workspaceID: workspaceID,
                        database: database
                    )
                },
                waitUntilChangeAvailableInDatabase: {
                    try await waitUntilChangeAvailableInDatabase(
                        mutation,
                        workspaceID: workspaceID,
                        database: database,
                        timeout: persistenceTimeout
                    )
                }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PlainTextResponseError {
            throw error
        } catch let error as WorkspaceUIHook.DispatchError {
            switch error {
            case .deliveryUnknown:
                throw PlainTextResponseError(
                    .serviceUnavailable,
                    message: "Could not determine whether the workspace change was delivered."
                )
            case .mutationInFlight:
                throw PlainTextResponseError(
                    .conflict,
                    message: "Another workspace change is still in progress."
                )
            }
        } catch PersistenceError.timedOut {
            throw PlainTextResponseError(
                .gatewayTimeout,
                message: "Timed out waiting for Conductor to save the workspace change."
            )
        } catch {
            throw PlainTextResponseError(
                .internalServerError,
                message: "Could not dispatch workspace change: \(error)"
            )
        }

        switch path {
        case .hook:
            return .noContent
        case .sqliteFallback:
            return .accepted
        }
    }

    private static let validStatuses = Set(
        [
            Workspace.Status.backlog,
            Workspace.Status.inProgress,
            Workspace.Status.inReview,
            Workspace.Status.done,
            Workspace.Status.canceled,
        ].map(\.rawValue)
    )

    private static func applyUIHookSQLiteFallback(
        _ mutation: WorkspaceMutation,
        workspaceID: String,
        database: any DatabaseWriter
    ) async throws {
        try await database.write { database in
            guard let workspace = try Workspace.find(workspaceID).fetchOne(database) else {
                throw PlainTextResponseError(.notFound, message: "Workspace not found.")
            }

            switch mutation {
            case .pinned(let isPinned):
                let pinnedAt = isPinned ? Date.now.ISO8601Format() : nil
                try Workspace
                    .find(workspaceID)
                    .update { $0.pinnedAt = #bind(pinnedAt) }
                    .execute(database)
            case .status(let status):
                try Workspace
                    .find(workspaceID)
                    .update { $0.manualStatus = #bind(status) }
                    .execute(database)
            case .unread(let isUnread):
                try setUnread(isUnread, workspace: workspace, database: database)
            }
        }
    }

    private static func waitUntilChangeAvailableInDatabase(
        _ mutation: WorkspaceMutation,
        workspaceID: String,
        database: any DatabaseReader,
        timeout: Duration
    ) async throws {
        // A browser setter succeeds only after Conductor's database reflects the requested value.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var isFirstAttempt = true
        while isFirstAttempt || clock.now < deadline {
            isFirstAttempt = false
            let isPersisted = try await database.read { database in
                guard let workspace = try Workspace.find(workspaceID).fetchOne(database) else {
                    return false
                }
                switch mutation {
                case .pinned(let isPinned):
                    return (workspace.pinnedAt != nil) == isPinned
                case .status(let status):
                    return workspace.manualStatus == status
                case .unread(let isUnread):
                    let unreadCount = try Session
                        .where {
                            $0.workspaceID.eq(workspaceID)
                                && !$0.isHidden
                                && $0.unreadCount.gt(0)
                        }
                        .fetchCount(database)
                    return (unreadCount > 0) == isUnread
                }
            }
            if isPersisted {
                return
            }
            // Pause between reads so this request does not busy-loop against Conductor's shared
            // database. Without the delay it would burn CPU and contend with the write it awaits.
            try await Task.sleep(for: .milliseconds(25))
        }
        throw PersistenceError.timedOut
    }

    private static func setUnread(
        _ isUnread: Bool,
        workspace: Workspace,
        database: Database
    ) throws {
        if isUnread {
            guard let activeSessionID = workspace.activeSessionID else {
                throw PlainTextResponseError(
                    .conflict,
                    message: "Workspace has no active session to mark unread."
                )
            }

            try Session
                .where {
                    $0.id.eq(activeSessionID)
                        && $0.workspaceID.eq(workspace.id)
                        && !$0.isHidden
                }
                .update {
                    $0.unreadCount = #sql("max(\($0.unreadCount), 1)")
                }
                .execute(database)

            guard database.changesCount == 1 else {
                throw PlainTextResponseError(
                    .conflict,
                    message: "Workspace active session is unavailable."
                )
            }
        } else {
            // Mark ALL sessions as read (though AFAIK you can only have one session unread)
            try Session
                .where {
                    $0.workspaceID.eq(workspace.id)
                        && !$0.isHidden
                        && $0.unreadCount.gt(0)
                }
                .update { $0.unreadCount = 0 }
                .execute(database)
        }
    }

    private enum PersistenceError: Error {
        case timedOut
    }
}

// Requiring exactly one typed field keeps PATCH commands absolute and unambiguous.
extension WorkspaceMutation: Decodable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw RequestDecodingError.invalidBody
        }

        self = switch key.stringValue {
        case "pinned":
            .pinned(isPinned: try container.decode(Bool.self, forKey: key))
        case "status":
            .status(try container.decode(String.self, forKey: key))
        case "unread":
            .unread(isUnread: try container.decode(Bool.self, forKey: key))
        default:
            throw RequestDecodingError.invalidBody
        }
    }

    private struct AnyCodingKey: CodingKey {
        let intValue: Int?
        let stringValue: String

        init?(intValue: Int) {
            self.intValue = intValue
            self.stringValue = String(intValue)
        }

        init?(stringValue: String) {
            self.intValue = nil
            self.stringValue = stringValue
        }
    }

    private enum RequestDecodingError: Error {
        case invalidBody
    }
}
