//
//  CloudWorkspaceCacheClient.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/27/26.
//

import Dependencies
import DependenciesMacros
import SQLiteData

@DependencyClient
public struct CloudWorkspaceCacheClient: Sendable {
    public var clear: @Sendable (
        _ keepingAccountID: String?
    ) async throws -> Void
}

extension CloudWorkspaceCacheClient: DependencyKey {
    public static let testValue = Self { _ in }

    public static var liveValue: Self {
        Self { keepingAccountID in
            @Dependency(\.defaultDatabase) var database
            try await database.write { db in
                try CloudWorkspaceMetadata.clearCachedRows(
                    in: db,
                    keepingAccountID: keepingAccountID
                )
            }
        }
    }
}

public extension DependencyValues {
    var cloudWorkspaceCacheClient: CloudWorkspaceCacheClient {
        get { self[CloudWorkspaceCacheClient.self] }
        set { self[CloudWorkspaceCacheClient.self] = newValue }
    }
}
