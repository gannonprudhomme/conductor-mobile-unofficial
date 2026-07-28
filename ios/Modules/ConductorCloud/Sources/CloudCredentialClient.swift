//
//  CloudCredentialClient.swift
//  ConductorCloud
//
//  Created by Gannon Prudomme on 7/24/26.
//

import Dependencies
import DependenciesMacros
import Foundation
import Security

@DependencyClient
public struct CloudCredentialClient: Sendable {
    public var deleteAPIKey: @Sendable () async throws -> Void
    public var loadAPIKey: @Sendable () async throws -> String?
    public var saveAPIKey: @Sendable (_ apiKey: String) async throws -> Void
}

public struct CloudCredentialError: Error, Equatable, LocalizedError, Sendable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String?
            ?? "Keychain returned status \(status)."
    }
}
extension CloudCredentialClient: DependencyKey {
    public static var liveValue: Self {
        Self {
            try KeychainStore.deleteAPIKey()
        } loadAPIKey: {
            try KeychainStore.loadAPIKey()
        } saveAPIKey: { apiKey in
            try KeychainStore.saveAPIKey(apiKey)
        }
    }
}

public extension DependencyValues {
    var cloudCredentialClient: CloudCredentialClient {
        get { self[CloudCredentialClient.self] }
        set { self[CloudCredentialClient.self] = newValue }
    }
}

private enum KeychainStore {
    static let account = "conductor-cloud-api-key"
    static let service = "com.gannonprudhomme.conductor-mobile-unofficial"

    static func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CloudCredentialError(status: status)
        }
    }

    static func loadAPIKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else {
            return nil
        }
        guard status == errSecSuccess else {
            throw CloudCredentialError(status: status)
        }
        guard let data = result as? Data,
              let apiKey = String(data: data, encoding: .utf8)
        else {
            throw CloudCredentialError(status: errSecDecode)
        }
        return apiKey
    }

    static func saveAPIKey(_ apiKey: String) throws {
        let data = Data(apiKey.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CloudCredentialError(status: addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw CloudCredentialError(status: updateStatus)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
        ]
    }
}
