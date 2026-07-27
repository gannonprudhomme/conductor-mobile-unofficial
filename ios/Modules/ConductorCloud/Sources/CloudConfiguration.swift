//
//  CloudConfiguration.swift
//  ConductorCloud
//
//  Created by Gannon Prudomme on 7/24/26.
//

import Foundation
import Sharing

public extension SharedKey where Self == FileStorageKey<Bool>.Default {
    static var cloudCredentialConfigured: Self {
        Self[
            .fileStorage(
                .applicationSupportDirectory
                    .appending(component: "cloud-credential-configured.json")
            ),
            default: false,
        ]
    }
}

public extension SharedKey where Self == FileStorageKey<String?>.Default {
    static var cloudAccountID: Self {
        Self[
            .fileStorage(
                .applicationSupportDirectory
                    .appending(component: "cloud-account-id.json")
            ),
            default: nil,
        ]
    }
}
