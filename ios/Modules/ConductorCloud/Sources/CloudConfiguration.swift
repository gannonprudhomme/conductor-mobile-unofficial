//
//  CloudConfiguration.swift
//  ConductorCloud
//
//  Created by Gannon Prudomme on 7/24/26.
//

import Foundation
import Sharing

public struct CloudConfiguration: Codable, Equatable, Sendable {
    public var accountID: String
    public var credentialRevision: Int

    public init(
        accountID: String,
        credentialRevision: Int = 0
    ) {
        self.accountID = accountID
        self.credentialRevision = credentialRevision
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accountID = try container.decode(String.self, forKey: .accountID)
        self.credentialRevision = try container.decodeIfPresent(
            Int.self,
            forKey: .credentialRevision
        ) ?? 0
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
