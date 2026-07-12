//
//  RepositoryQueriesTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
@testable import ConductorMobileData
import CustomDump
import Testing

struct RepositoryQueriesTests {
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
