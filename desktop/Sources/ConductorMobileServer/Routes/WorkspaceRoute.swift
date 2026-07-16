//
//  WorkspaceRoute.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Foundation
import Hummingbird
import SharedConductorData
import SQLiteData

enum WorkspaceRoute {
    static func post(
        request: Request,
        context: Server.RequestContext,
        database: any DatabaseWriter,
        openURL: @escaping @Sendable (URL) async throws -> Void
    ) async throws -> HTTPResponse.Status {
        let body = try await request.decode(as: CreateRequest.self, context: context)
        guard !body.repositoryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HTTPError(.badRequest, message: "repository_id must not be empty")
        }

        let repositoryPath = try await database.read { database in
            try Repository
                .find(body.repositoryID)
                .fetchOne(database)?
                .rootPath
        }
        guard let repositoryPath,
              !repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw HTTPError(.notFound, message: "Repository not found")
        }

        do {
            try await openURL(
                conductorDeepLink(
                    prompt: body.prompt ?? "",
                    repositoryPath: repositoryPath
                )
            )
        } catch {
            throw HTTPError(
                .internalServerError,
                message: "Could not open Conductor: \(error.localizedDescription)"
            )
        }

        return .accepted
    }

    static func patch(
        request: Request,
        context: Server.RequestContext,
        database: any DatabaseWriter
    ) async throws -> HTTPResponse.Status {
        let workspaceID = try context.parameters.require("workspaceID")
        let body = try await request.decode(as: PatchRequest.self, context: context)

        // Must provide at least one of the 3 routes to modify
        guard body.pinned != nil || body.status != nil || body.unread != nil else {
            throw HTTPError(.badRequest, message: "No workspace changes were provided")
        }

        if let status = body.status {
            guard validStatuses.contains(status) else {
                throw HTTPError(.badRequest, message: "Invalid workspace status: \(status)")
            }
        }

        try await database.write { database in
            guard let workspace = try Workspace
                .find(workspaceID)
                .fetchOne(database)
            else {
                throw HTTPError(.notFound, message: "Workspace not found")
            }

            if let unread = body.unread {
                try setUnread(
                    unread,
                    workspace: workspace,
                    database: database
                )
            }
            if let pinned = body.pinned {
                let pinnedAt = pinned ? Date.now.ISO8601Format() : nil
                try Workspace
                    .find(workspaceID)
                    .update {
                        $0.pinnedAt = #bind(pinnedAt)
                    }
                    .execute(database)
            }
            if let status = body.status {
                try Workspace
                    .find(workspaceID)
                    .update {
                        $0.manualStatus = #bind(status)
                    }
                    .execute(database)
            }
        }

        return .noContent
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

    private static func setUnread(
        _ unread: Bool,
        workspace: Workspace,
        database: Database
    ) throws {
        if unread {
            guard let activeSessionID = workspace.activeSessionID else {
                throw HTTPError(.conflict, message: "Workspace has no active session to mark unread")
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

            let numRowsChangedByUpdate = database.changesCount
            guard numRowsChangedByUpdate == 1 else {
                throw HTTPError(.conflict, message: "Workspace active session is unavailable")
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

    private static func conductorDeepLink(prompt: String, repositoryPath: String) -> URL {
        URL(
            string: "conductor://prompt=\(percentEncode(prompt))&path=\(percentEncode(repositoryPath))"
        )!
    }

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "-._~")
            )
        )!
    }

    static func openConductorURL(_ url: URL) async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "ConductorMobileServer.OpenURL",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "/usr/bin/open exited with status \(process.terminationStatus)"
                ]
            )
        }
    }

    private struct CreateRequest: Decodable, Sendable {
        let repositoryID: String
        let prompt: String?

        enum CodingKeys: String, CodingKey {
            case repositoryID = "repository_id"
            case prompt
        }
    }

    private struct PatchRequest: Decodable, Sendable {
        let pinned: Bool?
        let status: String?
        let unread: Bool?
    }
}
