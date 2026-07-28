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

    public init(accountID: String) {
        self.accountID = accountID
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
