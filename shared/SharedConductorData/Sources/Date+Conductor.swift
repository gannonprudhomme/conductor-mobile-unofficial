//
//  Date+Conductor.swift
//  SharedConductorData
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Foundation
import SQLiteData

public extension Date {
    struct ConductorDatabaseRepresentation: QueryRepresentable {
        public var queryOutput: Date

        public init(queryOutput: Date) {
            self.queryOutput = queryOutput
        }
    }

    static func conductorDate(from string: String) -> Date? {
        (try? Date(string, strategy: .iso8601))
            ?? conductorCloudDate(from: string)
            ?? DateFormatter.conductorSQLiteFractional.date(from: string)
            ?? DateFormatter.conductorSQLite.date(from: string)
    }

    private static func conductorCloudDate(from string: String) -> Date? {
        guard let separatorIndex = string.firstIndex(of: " ") else {
            return nil
        }

        var normalized = string
        normalized.replaceSubrange(separatorIndex...separatorIndex, with: "T")

        if let offsetIndex = normalized.lastIndex(where: { $0 == "+" || $0 == "-" }),
           normalized.distance(from: offsetIndex, to: normalized.endIndex) == 3,
           normalized[normalized.index(after: offsetIndex)...].allSatisfy(\.isNumber) {
            normalized.append(":00")
        }

        return try? Date(normalized, strategy: .iso8601)
    }
}

extension Date.ConductorDatabaseRepresentation: QueryBindable {
    public var queryBinding: QueryBinding {
        queryOutput
            .formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            .queryBinding
    }
}

extension Date.ConductorDatabaseRepresentation: QueryDecodable {
    public init(decoder: inout some QueryDecoder) throws {
        let string = try String(decoder: &decoder)
        guard let date = Date.conductorDate(from: string)
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Invalid Conductor date: \(string)")
            )
        }
        self.init(queryOutput: date)
    }
}

private extension DateFormatter {
    static let conductorSQLite = conductor(dateFormat: "yyyy-MM-dd HH:mm:ss")
    static let conductorSQLiteFractional = conductor(dateFormat: "yyyy-MM-dd HH:mm:ss.SSS")

    static func conductor(dateFormat: String) -> DateFormatter {
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .iso8601)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = dateFormat
        return dateFormatter
    }
}
