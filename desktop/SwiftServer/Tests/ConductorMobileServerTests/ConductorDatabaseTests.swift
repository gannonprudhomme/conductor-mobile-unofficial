//
//  ConductorDatabaseTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Foundation
import SQLiteData
import Testing

@testable import ConductorMobileServer

struct ConductorDatabaseTests {
    @Test("Conductor database access is read-only")
    func readOnlyDatabase() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let databaseURL = root.appending(path: "conductor.db")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = try DatabaseQueue(path: databaseURL.path)
        try writer.write { database in
            try database.execute(sql: "CREATE TABLE records (id INTEGER PRIMARY KEY)")
        }

        let reader = try ConductorDatabase.open(at: databaseURL)
        #expect(throws: (any Error).self) {
            try reader.read { database in
                try database.execute(sql: "INSERT INTO records DEFAULT VALUES")
            }
        }
    }
}
