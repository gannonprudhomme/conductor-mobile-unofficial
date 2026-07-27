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
