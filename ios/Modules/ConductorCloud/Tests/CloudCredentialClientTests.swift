//
//  CloudCredentialClientTests.swift
//  ConductorCloudTests
//
//  Created by Gannon Prudomme on 7/24/26.
//

@testable import ConductorCloud
import Dependencies
import Testing

struct CloudCredentialClientTests {
    @Test("API-key storage can be replaced by a Keychain-free mock")
    func mockCredentialStorage() async throws {
        let storedAPIKey = LockIsolated<String?>(nil)
        var credentials = CloudCredentialClient()
        credentials.loadAPIKey = {
            storedAPIKey.value
        }
        credentials.saveAPIKey = { apiKey in
            storedAPIKey.setValue(apiKey)
        }
        credentials.deleteAPIKey = {
            storedAPIKey.setValue(nil)
        }

        try await credentials.saveAPIKey(apiKey: "synthetic-api-key")
        #expect(try await credentials.loadAPIKey() == "synthetic-api-key")

        try await credentials.deleteAPIKey()
        #expect(try await credentials.loadAPIKey() == nil)
    }
}
