//
//  SessionRoute.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/19/26.
//

import Dependencies
import Foundation
import Hummingbird
import SharedConductorData
import SQLiteData

enum SessionRoute {
    static func patch(
        request: Request,
        context: Server.RequestContext,
        database: any DatabaseReader,
        persistenceTimeout: Duration
    ) async throws -> HTTPResponse.Status {
        @Dependency(\.continuousClock) var clock
        @Dependency(\.workspaceUIHook) var uiHook

        let workspaceID = try context.parameters.require("workspaceID")
        let sessionID = try context.parameters.require("sessionID")
        let mutation: SessionMutation
        do {
            mutation = try await request.decode(as: SessionMutation.self, context: context)
        } catch {
            throw PlainTextResponseError(.badRequest, message: "Invalid session change.")
        }

        guard try await session(
            id: sessionID,
            workspaceID: workspaceID,
            database: database
        ) != nil else {
            throw PlainTextResponseError(.notFound, message: "Session not found.")
        }

        do {
            try await uiHook.mutateSession(
                requestID: UUID(),
                command: .session(
                    id: sessionID,
                    workspaceID: workspaceID,
                    mutation: mutation
                )
            ) {
                try await waitUntilPersisted(
                    mutation,
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    database: database,
                    clock: clock,
                    timeout: persistenceTimeout
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WorkspaceUIHook.CommandDispatchError {
            switch error {
            case .commandFailed(let message):
                throw PlainTextResponseError(
                    .internalServerError,
                    message: "Could not change session: \(message)"
                )
            case .deliveryUnknown:
                throw PlainTextResponseError(
                    .serviceUnavailable,
                    message: "Could not determine whether the session change was delivered."
                )
            case .listenerUnavailable:
                throw PlainTextResponseError(
                    .serviceUnavailable,
                    message: "Conductor's workspace UI hook is unavailable."
                )
            case .persistenceTimedOut:
                throw PlainTextResponseError(
                    .gatewayTimeout,
                    message: "Timed out waiting for Conductor to save the session change."
                )
            }
        } catch let error as WorkspaceUIHook.DispatchError {
            switch error {
            case .deliveryUnknown:
                throw PlainTextResponseError(
                    .serviceUnavailable,
                    message: "Could not determine whether the session change was delivered."
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
                message: "Timed out waiting for Conductor to save the session change."
            )
        } catch {
            throw PlainTextResponseError(
                .internalServerError,
                message: "Could not change session: \(error)"
            )
        }

        return .noContent
    }

    private static func session(
        id: Session.ID,
        workspaceID: Workspace.ID,
        database: any DatabaseReader
    ) async throws -> Session? {
        try await database.read { database in
            try Session
                .where { $0.id.eq(id).and($0.workspaceID.eq(workspaceID)) }
                .fetchOne(database)
        }
    }

    private static func waitUntilPersisted<C: Clock>(
        _ mutation: SessionMutation,
        sessionID: Session.ID,
        workspaceID: Workspace.ID,
        database: any DatabaseReader,
        clock: C,
        timeout: Duration
    ) async throws where C.Duration == Duration {
        let start = clock.now
        while !Task.isCancelled {
            let session = try await session(
                id: sessionID,
                workspaceID: workspaceID,
                database: database
            )
            let isPersisted = switch mutation {
            case let .hidden(isHidden):
                session?.isHidden == isHidden
            case .title(let title):
                session?.title == title
            }
            if isPersisted {
                return
            }

            let elapsed = start.duration(to: clock.now)
            guard elapsed < timeout else {
                throw PersistenceError.timedOut
            }

            try await clock.sleep(for: min(.milliseconds(3), timeout - elapsed))
        }

        throw CancellationError()
    }

    private enum PersistenceError: Error {
        case timedOut
    }
}

extension SessionMutation: Decodable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw RequestDecodingError.invalidBody
        }

        self = switch key.stringValue {
        case "hidden":
            .hidden(isHidden: try container.decode(Bool.self, forKey: key))
        case "title":
            .title(try Self.title(in: container, forKey: key))
        default:
            throw RequestDecodingError.invalidBody
        }
    }

    private static func title(
        in container: KeyedDecodingContainer<AnyCodingKey>,
        forKey key: AnyCodingKey
    ) throws -> String {
        let title = try container.decode(String.self, forKey: key)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw RequestDecodingError.invalidBody
        }
        return title
    }

    private enum RequestDecodingError: Error {
        case invalidBody
    }
}
