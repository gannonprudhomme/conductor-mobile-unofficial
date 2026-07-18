//
//  PullRequestSnapshotTests.swift
//  SharedConductorDataTests
//
//  Created by Gannon Prudomme on 7/16/26.
//

import Foundation
import SharedConductorData
import Testing

struct PullRequestSnapshotTests {
    @Test("Unknown external statuses survive decoding and encoding")
    func unknownStatuses() throws {
        let snapshot = try JSONDecoder.conductor.decode(
            PullRequestSnapshot.self,
            from: Data(
                """
                {
                  "url": "https://github.com/example/repository/pull/42",
                  "is_draft": false,
                  "is_merged": false,
                  "merge_state_status": "FUTURE_MERGE_STATE",
                  "checks_status": "future-checks-state"
                }
                """.utf8
            )
        )

        #expect(snapshot.mergeStateStatus?.rawValue == "FUTURE_MERGE_STATE")
        #expect(snapshot.checksStatus?.rawValue == "future-checks-state")

        let roundTrip = try JSONDecoder.conductor.decode(
            PullRequestSnapshot.self,
            from: JSONEncoder.conductor.encode(snapshot)
        )

        #expect(roundTrip == snapshot)
    }
}
