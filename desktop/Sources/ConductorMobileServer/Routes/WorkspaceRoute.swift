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
    static func post(
        request: Request,
        context: Server.RequestContext,
        database: any DatabaseWriter,
        creationTimeout: Duration,
        uiMutationTimeout: Duration
    ) async throws -> Response {
        @Dependency(\.continuousClock) var clock
        @Dependency(\.workspaceUIHook) var uiHook

        let body = try await request.decode(as: CreateRequest.self, context: context)
        guard let parsedWorkspaceID = UUID(uuidString: body.workspaceID) else {
            throw PlainTextResponseError(.badRequest, message: "workspace_id must be a UUID.")
        }
        let workspaceID = parsedWorkspaceID.uuidString.lowercased()
        guard !body.repositoryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlainTextResponseError(.badRequest, message: "repository_id must not be empty.")
        }
        let repositoryExists = try await database.read { database in
            try Repository.find(body.repositoryID).fetchOne(database) != nil
        }
        guard repositoryExists else {
            throw PlainTextResponseError(.notFound, message: "Repository not found.")
        }
        let agentType = Session.AgentType(rawValue: body.agentType)
        let model = Session.Model(rawValue: body.model)
        guard Session.Model.models(for: agentType).contains(model) else {
            throw PlainTextResponseError(
                .badRequest,
                message: "Model is not available for the selected agent."
            )
        }

        if let createdWorkspace = try await loadCreatedWorkspace(
            workspaceID: workspaceID,
            database: database
        ) {
            try validateCreation(
                createdWorkspace,
                repositoryID: body.repositoryID,
                agentType: agentType,
                model: model
            )
            let updatedWorkspace = try await settingFastMode(
                body.isFastModeEnabled,
                for: createdWorkspace,
                database: database,
                clock: clock,
                timeout: uiMutationTimeout,
                uiHook: uiHook
            )
            return try JSONEncoder.conductor.encode(
                updatedWorkspace,
                from: request,
                context: context
            )
        }

        let command = CreateWorkspaceCommand(
            repositoryID: body.repositoryID,
            workspaceID: workspaceID,
            agentType: agentType.rawValue,
            model: model.rawValue
        )

        do {
            let didDispatch = try await uiHook.createWorkspace(
                command: command,
                waitUntilChangeAvailableInDatabase: {
                    let didPersist = try await waitForCreatedWorkspace(
                        workspaceID: workspaceID,
                        database: database,
                        clock: clock,
                        timeout: creationTimeout
                    )
                    guard didPersist else {
                        throw PersistenceError.timedOut
                    }
                }
            )
            guard didDispatch else {
                throw PlainTextResponseError(
                    .serviceUnavailable,
                    message: "Conductor's Workspace UI hook is not connected."
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PlainTextResponseError {
            throw error
        } catch let error as WorkspaceUIHook.DispatchError {
            switch error {
            case .deliveryUnknown:
                throw PlainTextResponseError(
                    .serviceUnavailable,
                    message: "Could not determine whether workspace creation was delivered."
                )
            case .listenerUnavailable:
                throw PlainTextResponseError(
                    .serviceUnavailable,
                    message: "Conductor's workspace UI hook is unavailable."
                )
            case .mutationInFlight:
                throw PlainTextResponseError(
                    .conflict,
                    message: "Another Conductor UI change is still in progress."
                )
            }
        } catch PersistenceError.timedOut {
            throw PlainTextResponseError(
                .gatewayTimeout,
                message: "Timed out waiting for Conductor to create the workspace."
            )
        } catch {
            throw PlainTextResponseError(
                .internalServerError,
                message: "Could not create workspace: \(error)"
            )
        }

        guard let createdWorkspace = try await loadCreatedWorkspace(
            workspaceID: workspaceID,
            database: database
        ) else {
            throw PlainTextResponseError(
                .internalServerError,
                message: "Conductor created an incomplete workspace."
            )
        }
        try validateCreation(
            createdWorkspace,
            repositoryID: body.repositoryID,
            agentType: agentType,
            model: model
        )
        let updatedWorkspace = try await settingFastMode(
            body.isFastModeEnabled,
            for: createdWorkspace,
            database: database,
            clock: clock,
            timeout: uiMutationTimeout,
            uiHook: uiHook
        )
        return try JSONEncoder.conductor.encode(
            updatedWorkspace,
            from: request,
            context: context
        )
    }

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
        if case .branch(let branch) = mutation {
            guard !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PlainTextResponseError(.badRequest, message: "Branch name cannot be empty.")
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
                command: .workspace(id: workspaceID, mutation: mutation),
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
            case .listenerUnavailable:
                throw PlainTextResponseError(
                    .serviceUnavailable,
                    message: "Conductor's workspace UI hook is unavailable."
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
            case .archive:
                // Archiving runs Conductor's cleanup flow and cannot safely fall back to SQLite.
                throw WorkspaceUIHook.DispatchError.listenerUnavailable
            case .branch:
                // Conductor must keep Git and its workspace metadata in sync during a rename.
                throw WorkspaceUIHook.DispatchError.listenerUnavailable
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
                case .archive:
                    return workspace.state == .archiving || workspace.state == .archived
                case .branch(let branch):
                    return workspace.branch == branch && workspace.userSetBranchName == 1
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

    private struct CreateRequest: Decodable, Sendable {
        let workspaceID: Workspace.ID
        let repositoryID: Repository.ID
        let agentType: String
        let model: String
        let isFastModeEnabled: Bool

        enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
            case repositoryID = "repository_id"
            case agentType = "agent_type"
            case model
            case isFastModeEnabled = "fast_mode"
        }
    }

    private static func settingFastMode<C: Clock>(
        _ isFastModeEnabled: Bool,
        for createdWorkspace: CreatedWorkspace,
        database: any DatabaseWriter,
        clock: C,
        timeout: Duration,
        uiHook: WorkspaceUIHook
    ) async throws -> CreatedWorkspace where C.Duration == Duration {
        let sessionID = createdWorkspace.session.id
        guard (createdWorkspace.session.isFastModeEnabled ?? false) != isFastModeEnabled else {
            return createdWorkspace
        }

        do {
            _ = try await uiHook.dispatch(
                command: .sessionFastMode(
                    sessionID: sessionID,
                    isEnabled: isFastModeEnabled
                )
            ) {
                try await database.write { database in
                    try Session
                        .find(sessionID)
                        .update { $0.isFastModeEnabled = #bind(isFastModeEnabled) }
                        .execute(database)
                }
            } waitUntilChangeAvailableInDatabase: {
                let didPersist = try await waitForSessionFastMode(
                    isFastModeEnabled,
                    sessionID: sessionID,
                    database: database,
                    clock: clock,
                    timeout: timeout
                )
                guard didPersist else {
                    throw PersistenceError.timedOut
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WorkspaceUIHook.DispatchError {
            switch error {
            case .deliveryUnknown:
                throw PlainTextResponseError(
                    .serviceUnavailable,
                    message: "Could not determine whether Fast Mode was delivered."
                )
            case .listenerUnavailable:
                throw PlainTextResponseError(
                    .serviceUnavailable,
                    message: "Conductor's workspace UI hook is unavailable."
                )
            case .mutationInFlight:
                throw PlainTextResponseError(
                    .conflict,
                    message: "Another Conductor UI change is still in progress."
                )
            }
        } catch PersistenceError.timedOut {
            throw PlainTextResponseError(
                .gatewayTimeout,
                message: "Timed out waiting for Conductor to save Fast Mode."
            )
        } catch {
            throw PlainTextResponseError(
                .internalServerError,
                message: "Could not save Fast Mode: \(error)"
            )
        }

        guard let updatedWorkspace = try await loadCreatedWorkspace(
            workspaceID: createdWorkspace.workspace.id,
            database: database
        ) else {
            throw PlainTextResponseError(
                .internalServerError,
                message: "Conductor created an incomplete workspace."
            )
        }
        return updatedWorkspace
    }

    private static func validateCreation(
        _ createdWorkspace: CreatedWorkspace,
        repositoryID: Repository.ID,
        agentType: Session.AgentType,
        model: Session.Model
    ) throws {
        guard createdWorkspace.workspace.repositoryID == repositoryID,
              createdWorkspace.session.agentType == agentType,
              createdWorkspace.session.model == model
        else {
            throw PlainTextResponseError(
                .conflict,
                message: "workspace_id is already associated with another creation request."
            )
        }
    }

    private static func waitForCreatedWorkspace<C: Clock>(
        workspaceID: Workspace.ID,
        database: any DatabaseReader,
        clock: C,
        timeout: Duration
    ) async throws -> Bool where C.Duration == Duration {
        let start = clock.now
        while !Task.isCancelled {
            if try await loadCreatedWorkspace(workspaceID: workspaceID, database: database) != nil {
                return true
            }

            let elapsed = start.duration(to: clock.now)
            guard elapsed < timeout else {
                return false
            }

            try await clock.sleep(for: min(.milliseconds(25), timeout - elapsed))
        }
        throw CancellationError()
    }

    private static func waitForSessionFastMode<C: Clock>(
        _ isFastModeEnabled: Bool,
        sessionID: Session.ID,
        database: any DatabaseReader,
        clock: C,
        timeout: Duration
    ) async throws -> Bool where C.Duration == Duration {
        let start = clock.now
        while !Task.isCancelled {
            let persistedFastMode = try await database.read { database in
                try Session.find(sessionID).fetchOne(database)?.isFastModeEnabled
            }
            if persistedFastMode == isFastModeEnabled {
                return true
            }

            let elapsed = start.duration(to: clock.now)
            guard elapsed < timeout else {
                return false
            }

            try await clock.sleep(for: min(.milliseconds(25), timeout - elapsed))
        }
        throw CancellationError()
    }

    private static func loadCreatedWorkspace(
        workspaceID: Workspace.ID,
        database: any DatabaseReader
    ) async throws -> CreatedWorkspace? {
        try await database.read { database in
            guard let workspace = try Workspace.find(workspaceID).fetchOne(database) else {
                return nil
            }
            // Conductor can persist a workspace and its initial session before setting
            // `active_session_id`. Requiring that relationship would hold the UI mutation slot
            // until the creation request times out.
            let session: Session? = if let sessionID = workspace.activeSessionID {
                try Session
                    .where {
                        $0.id.eq(sessionID)
                            && $0.workspaceID.eq(workspaceID)
                    }
                    .fetchOne(database)
            } else {
                // The oldest session is the one created with the workspace. The ID makes retries
                // deterministic when multiple sessions have the same timestamp.
                try Session
                    .where { $0.workspaceID.eq(workspaceID) }
                    .order { ($0.createdAt, $0.id) }
                    .fetchOne(database)
            }
            guard let session else {
                return nil
            }
            return CreatedWorkspace(workspace: workspace, session: session)
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
        case "archive":
            if try container.decode(Bool.self, forKey: key) {
                .archive
            } else {
                throw RequestDecodingError.invalidBody
            }
        case "branch":
            .branch(try container.decode(String.self, forKey: key))
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

    private enum RequestDecodingError: Error {
        case invalidBody
    }
}
