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
            @Shared(.cloudConfiguration) var configuration

            $configuration.withLock {
                $0 = CloudConfiguration(
                    accountID: "user-1:organization-1:workspace-1"
                )
            }

            #expect(
                configuration?.accountID
                    == "user-1:organization-1:workspace-1"
            )
            let encodedConfiguration = try JSONEncoder().encode(configuration)
            #expect(
                !String(decoding: encodedConfiguration, as: UTF8.self)
                    .contains("api-key")
            )
        }
    }

    @Test("Legacy configuration receives a credential generation")
    func legacyConfigurationMigration() throws {
        let configuration = try JSONDecoder().decode(
            CloudConfiguration.self,
            from: Data(#"{"accountID":"account"}"#.utf8)
        )

        #expect(configuration.accountID == "account")
        #expect(configuration.credentialGeneration.uuidString.isEmpty == false)
    }
}
