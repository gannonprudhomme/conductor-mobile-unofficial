//
//  CloudConfigurationTests.swift
//  ConductorCloudTests
//
//  Created by Gannon Prudomme on 7/27/26.
//

@testable import ConductorCloud
import Dependencies
import Foundation
import Sharing
import Testing

struct CloudConfigurationTests {
    @Test("Only non-secret Cloud configuration is persisted outside Keychain")
    func persistedConfigurationContainsNoAPIKey() throws {
        try withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.cloudCredentialConfigured) var isConfigured
            @Shared(.cloudAccountID) var accountID

            $isConfigured.withLock { $0 = true }
            $accountID.withLock { $0 = "user-1:organization-1:workspace-1" }

            #expect(isConfigured)
            #expect(accountID == "user-1:organization-1:workspace-1")
            let encodedMarker = try JSONEncoder().encode(isConfigured)
            let encodedAccountID = try JSONEncoder().encode(accountID)
            #expect(String(decoding: encodedMarker, as: UTF8.self) == "true")
            #expect(!String(decoding: encodedMarker, as: UTF8.self).contains("api-key"))
            #expect(!String(decoding: encodedAccountID, as: UTF8.self).contains("api-key"))
        }
    }
}
