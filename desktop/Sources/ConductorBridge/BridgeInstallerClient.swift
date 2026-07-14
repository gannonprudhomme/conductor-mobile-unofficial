//
//  BridgeInstallerClient.swift
//  ConductorBridge
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Foundation

public struct BridgeStatus: Decodable, Equatable, Sendable {
    public var isInstalledInApplications: Bool
    public var isInstalledInApplicationSupport: Bool
    public var isReachable: Bool

    public init(
        isInstalledInApplications: Bool = false,
        isInstalledInApplicationSupport: Bool = false,
        isReachable: Bool = false
    ) {
        self.isInstalledInApplications = isInstalledInApplications
        self.isInstalledInApplicationSupport = isInstalledInApplicationSupport
        self.isReachable = isReachable
    }

    enum CodingKeys: String, CodingKey {
        case isInstalledInApplications = "is_bridge_installed_in_applications"
        case isInstalledInApplicationSupport = "is_bridge_installed_in_application_support"
        case isReachable = "is_bridge_reachable"
    }
}

// Entirely written by Codex, but not putting too much salt into it cause I'll pretty much rewrite it
// when we drop the last bit of Rust
public struct BridgeInstallerClient: Sendable {
    public init() {
    }

    public func install() async throws {
        guard let resourcesURL = Bundle.main.resourceURL?.appending(path: "sidecar-proxy") else {
            throw BridgeInstallerError.missingResources
        }

        _ = try await run(arguments: ["install", "--resources", resourcesURL.path])
    }

    public func uninstall() async throws {
        _ = try await run(arguments: ["uninstall"])
    }

    public func status() async throws -> BridgeStatus {
        let output = try await run(arguments: ["status"])
        return try JSONDecoder().decode(BridgeStatus.self, from: output)
    }

    private func run(arguments: [String]) async throws -> Data {
        let helperURL = Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/conductor-bridge-installer")

        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw BridgeInstallerError.missingHelper
        }

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            let errors = Pipe()

            process.executableURL = helperURL
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = errors

            try process.run()
            process.waitUntilExit()

            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()

            guard process.terminationStatus == EXIT_SUCCESS else {
                let message = String(decoding: errorData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw BridgeInstallerError.commandFailed(message)
            }

            return outputData
        }.value
    }
}

private enum BridgeInstallerError: LocalizedError {
    case commandFailed(String)
    case missingHelper
    case missingResources

    var errorDescription: String? {
        switch self {
        case let .commandFailed(message):
            message.isEmpty ? "The bridge installer failed." : message

        case .missingHelper:
            "The bundled bridge installer is missing."

        case .missingResources:
            "The bundled bridge resources are missing."
        }
    }
}
