//
//  ConductorDatabase.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Foundation
import SQLiteData

enum ConductorDatabase {
    static func open(at url: URL) throws -> any DatabaseReader {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { database in
            // SQLite's query_only pragma makes every pooled connection reject writes. It is a second
            // guard in case this database is ever opened with a less restrictive configuration.
            try #sql("PRAGMA query_only = ON").execute(database)
        }
        return try DatabasePool(path: url.path, configuration: configuration)
    }
}
