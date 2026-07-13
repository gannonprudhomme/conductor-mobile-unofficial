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
    @Test("Conductor database access is writable")
    func writableDatabase() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
        let databaseURL = root.appending(path: "conductor.db")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = try DatabaseQueue(path: databaseURL.path)
        try writer.write { database in
            try createTestConductorSchema(in: database)
            try database.execute(sql: "CREATE TABLE records (id INTEGER PRIMARY KEY)")
        }

        let database = try ConductorDatabase.open(at: databaseURL)
        let record = TestRecord(id: 1)
        try database.write { database in
            try TestRecord
                .insert { record }
                .execute(database)
        }
        let count = try database.read { database in
            try TestRecord
                .fetchCount(database)
        }
        #expect(count == 1)
    }

    @Test("Opening a missing Conductor database does not create it")
    func missingDatabase() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let databaseURL = root.appending(path: "conductor.db")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: DatabaseError.self) {
            _ = try ConductorDatabase.open(at: databaseURL)
        }
        #expect(!FileManager.default.fileExists(atPath: databaseURL.path))
    }

    @Test("Opening an unexpected Conductor schema fails")
    func unexpectedSchema() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let databaseURL = root.appending(path: "conductor.db")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try DatabaseQueue(path: databaseURL.path)

        #expect(throws: DatabaseError.self) {
            _ = try ConductorDatabase.open(at: databaseURL)
        }
    }
}

@Table("records")
private struct TestRecord: Identifiable {
    let id: Int
}
