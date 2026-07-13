//
//  ConductorDatabase.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Foundation
import SharedConductorData
import SQLiteData

enum ConductorDatabase {
    static func open(at url: URL) throws -> any DatabaseWriter {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { database in
            // Execute typed, zero-row queries so opening fails if Conductor's expected tables or
            // columns are missing without reading any records.
            _ = try Workspace.limit(0).fetchAll(database)
            _ = try Session.limit(0).fetchAll(database)
            _ = try Repository.limit(0).fetchAll(database)
            _ = try Message.limit(0).fetchAll(database)
        }
        // DatabasePool opens read connections with SQLITE_OPEN_READONLY, which conflicts with
        // mode=rw. Keep a queue so a missing Conductor database fails instead of being created.
        return try DatabaseQueue(
            path: url.absoluteString + "?mode=rw",
            configuration: configuration
        )
    }
}
