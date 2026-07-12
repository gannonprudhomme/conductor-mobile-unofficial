//
//  RepositoryTests.swift
//  SharedConductorDataTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import Foundation
import SQLiteData
import Testing

struct RepositoryTests {
    @Test("Repository decodes a full Conductor row")
    func decodesFullRow() throws {
        let repository = try JSONDecoder.conductor.decode(
            Repository.self,
            from: Data(
                """
                {
                  "id": "9e1d19a8-796e-4dac-b9e8-90e5270bceae",
                  "remote_url": "https://github.com/acme/conductor-mobile.git",
                  "name": "conductor-mobile",
                  "default_branch": "main",
                  "root_path": "/Users/acme/conductor-mobile",
                  "setup_script": "npm install",
                  "created_at": "2026-02-15 01:28:12",
                  "updated_at": "2026-06-16 06:28:18",
                  "storage_version": 3,
                  "archive_script": null,
                  "display_order": 2,
                  "run_script": null,
                  "run_script_mode": "concurrent",
                  "remote": "origin",
                  "custom_prompt_code_review": null,
                  "custom_prompt_create_pr": null,
                  "custom_prompt_rename_branch": null,
                  "conductor_config": null,
                  "custom_prompt_general": null,
                  "icon": "monitor",
                  "hidden": 0,
                  "custom_prompt_fix_errors": null,
                  "custom_prompt_resolve_merge_conflicts": null,
                  "file_include_globs": null,
                  "spotlight_testing": 0
                }
                """.utf8
            )
        )

        #expect(repository.id == "9e1d19a8-796e-4dac-b9e8-90e5270bceae")
        #expect(repository.name == "conductor-mobile")
        #expect(repository.defaultBranch == "main")
        #expect(repository.displayOrder == 2)
        #expect(repository.runScriptMode == "concurrent")
        #expect(repository.storageVersion == 3)
        #expect(repository.hidden == 0)
        #expect(repository.icon == "monitor")
    }

    @Test("Repository SQLite decoding parses ISO-8601 dates")
    func sqliteDateDecoding() throws {
        let database = try DatabaseQueue()
        try database.write { db in
            try db.execute(
                sql: """
                    CREATE TABLE repos (
                      created_at TEXT NOT NULL,
                      updated_at TEXT NOT NULL
                    );
                    INSERT INTO repos (created_at, updated_at)
                    VALUES ('2026-07-09T00:00:01.125Z', '2026-07-09T00:00:02Z');
                    """
            )
        }

        let dates = try #require(
            database.read { db in
                try Repository
                    .select { ($0.createdAt, $0.updatedAt) }
                    .fetchOne(db)
            }
        )

        #expect(dates.0 == Date(timeIntervalSince1970: 1_783_555_201.125))
        #expect(dates.1 == Date(timeIntervalSince1970: 1_783_555_202))
    }
}
