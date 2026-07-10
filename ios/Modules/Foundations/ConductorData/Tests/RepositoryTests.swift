import ConductorData
import CustomDump
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
                  "icon": null,
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
    }

    @Test("All repositories are stably sorted by name")
    func sortedByName() throws {
        let database = try appDatabase()

        try database.write { db in
            try Repository.insert { Repository.preview(id: "repo-1", name: "TrialSongs") }.execute(db)
            try Repository.insert { Repository.preview(id: "repo-2", name: "conductor-mobile") }.execute(db)
            try Repository.insert { Repository.preview(id: "repo-3", name: "Empty") }.execute(db)
            try Repository.insert { Repository.preview(id: "repo-4", name: "MovieRating") }.execute(db)
            try Repository.insert { Repository.preview(id: "repo-5", name: "conductor-mobile") }.execute(db)
        }

        let repositories = try database.read { db in
            try Repository.all
                .order { ($0.name.lower(), $0.id) }
                .fetchAll(db)
        }

        expectNoDifference(
            repositories.map(\.id),
            ["repo-2", "repo-5", "repo-3", "repo-4", "repo-1"]
        )
    }
}
