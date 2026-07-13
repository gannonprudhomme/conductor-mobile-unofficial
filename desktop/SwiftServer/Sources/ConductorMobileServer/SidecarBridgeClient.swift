//
//  SidecarBridgeClient.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
struct SidecarBridgeClient: Sendable {
    var sendMessage: @Sendable (RuntimeMessageRequest) async throws -> Void

    struct RuntimeMessageRequest: Encodable, Equatable, Sendable {
        let agentType: String
        let cwd: String
        let message: String
        let model: String
        let sessionID: String
        let workspaceID: String

        private enum CodingKeys: String, CodingKey {
            case agentType
            case cwd
            case message
            case model
            case sessionID = "sessionId"
            case workspaceID = "workspaceId"
        }
    }

    struct ResponseError: Error, Sendable {
        let statusCode: Int
        let message: String
    }

    fileprivate struct ErrorResponse: Decodable {
        let error: String
    }
}

extension SidecarBridgeClient: DependencyKey {
    static var liveValue: Self {
        Self { message in
            try await post(
                message,
                to: URL(string: "http://127.0.0.1:49321/message")!,
                timeoutInterval: 125
            )
        }
    }
}

private func post<Body: Encodable>(
    _ body: Body,
    to url: URL,
    timeoutInterval: TimeInterval
) async throws {
    @Dependency(\.urlSession) var urlSession

    var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
    request.httpMethod = "POST"
    request.httpBody = try JSONEncoder().encode(body)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let (data, response) = try await urlSession.data(for: request)
    guard let response = response as? HTTPURLResponse else {
        throw SidecarBridgeClient.ResponseError(
            statusCode: 502,
            message: "The Conductor sidecar bridge returned an invalid response."
        )
    }
    guard (200..<300).contains(response.statusCode) else {
        let bridgeError = try? JSONDecoder().decode(
            SidecarBridgeClient.ErrorResponse.self,
            from: data
        )
        throw SidecarBridgeClient.ResponseError(
            statusCode: response.statusCode,
            message: bridgeError?.error ?? String(decoding: data, as: UTF8.self)
        )
    }
}
