//
//  JSONCodersTests.swift
//  SharedConductorDataTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import Foundation
import Testing

struct JSONCodersTests {
    @Test("Conductor JSON coders round-trip fractional dates")
    func fractionalDateRoundTrip() throws {
        let timestamp = Timestamp(date: Date(timeIntervalSince1970: 0.125))
        let data = try JSONEncoder.conductor.encode(timestamp)

        #expect(
            String(decoding: data, as: UTF8.self)
                == #"{"date":"1970-01-01T00:00:00.125Z"}"#
        )
        #expect(try JSONDecoder.conductor.decode(Timestamp.self, from: data) == timestamp)
    }
}

private struct Timestamp: Codable, Equatable {
    let date: Date
}
