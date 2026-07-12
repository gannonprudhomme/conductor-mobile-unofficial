//
//  JSONCoders+Conductor.swift
//  SharedConductorData
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Foundation

public extension JSONDecoder {
    static var conductor: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)

            if let date = Date.conductorDate(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid date: \(string)"
            )
        }
        return decoder
    }
}

public extension JSONEncoder {
    static var conductor: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(
                date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            )
        }
        return encoder
    }
}
