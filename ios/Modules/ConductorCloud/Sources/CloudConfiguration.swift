//
//  CloudConfiguration.swift
//  ConductorCloud
//
//  Created by Gannon Prudomme on 7/24/26.
//

import Foundation
import Sharing

public struct CloudConfiguration: Codable, Equatable, Sendable {
    private static let legacyCredentialGeneration = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)
    )

    public var accountID: String
    public var credentialGeneration: UUID

    public init(
        accountID: String,
        credentialGeneration: UUID = UUID()
    ) {
        self.accountID = accountID
        self.credentialGeneration = credentialGeneration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try container.decode(String.self, forKey: .accountID)
        credentialGeneration =
            try container.decodeIfPresent(
                UUID.self,
                forKey: .credentialGeneration
            ) ?? Self.legacyCredentialGeneration
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountID, forKey: .accountID)
        try container.encode(
            credentialGeneration,
            forKey: .credentialGeneration
        )
    }

    private enum CodingKeys: String, CodingKey {
        case accountID
        case credentialGeneration
    }
}

public extension SharedKey
where Self == FileStorageKey<CloudConfiguration?>.Default {
    static var cloudConfiguration: Self {
        Self[
            .fileStorage(
                .applicationSupportDirectory
                    .appending(component: "cloud-configuration.json")
            ),
            default: nil,
        ]
    }
}
