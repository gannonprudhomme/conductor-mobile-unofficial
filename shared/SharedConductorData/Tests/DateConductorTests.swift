//
//  DateConductorTests.swift
//  SharedConductorDataTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import Foundation
import Testing

struct DateConductorTests {
    @Test(
        "Conductor dates parse SQLite and ISO-8601 formats",
        arguments: [
            "2026-07-09 00:00:01",
            "2026-07-09 00:00:01.125",
            "2026-07-09T00:00:01.125Z",
        ]
    )
    func parsing(timestamp: String) {
        #expect(Date.conductorDate(from: timestamp) != nil)
    }
}
