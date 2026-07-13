//
//  DesktopClientTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

@testable import ConductorMobileData
import CustomDump
import Foundation
import SharedConductorData
import Testing

struct DesktopClientTests {
    @Test("Desktop client errors include response details")
    func errorDescriptions() {
        #expect(
            DesktopClientError.requestFailed(statusCode: 500, message: "boom").localizedDescription
                == "The desktop service returned HTTP 500: boom"
        )

        #expect(
            DesktopClientError.requestFailed(statusCode: 404, message: "").localizedDescription
                == "The desktop service returned HTTP 404."
        )
    }

    @Test("Conductor decoder accepts SQLite and ISO 8601 dates")
    func dateDecoding() throws {
        let dates = try JSONDecoder.conductor.decode(
            [Date].self,
            from: Data(
                """
                [
                  "2026-07-09 00:00:00",
                  "2026-07-09T00:00:00Z",
                  "2026-07-09T00:00:00.000Z"
                ]
                """.utf8
            )
        )

        expectNoDifference(
            dates,
            Array(repeating: Date(timeIntervalSince1970: 1_783_555_200), count: 3)
        )
    }

    @Test("Repository icon URLs use the desktop icon endpoint")
    func repositoryIconURL() {
        let repository = Repository(
            id: "repository-1",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        expectNoDifference(
            DesktopClient.repositoryIconURL(for: repository).absoluteString,
            "http://192.168.0.32:3768/repositories/repository-1/icon"
        )
    }
}
