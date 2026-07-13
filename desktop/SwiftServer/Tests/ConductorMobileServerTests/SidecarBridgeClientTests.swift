//
//  SidecarBridgeClientTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Dependencies
import Foundation
import Synchronization
import Testing

@testable import ConductorMobileServer

struct SidecarBridgeClientTests {
    @Test("Sidecar bridge requests use the proxy's JSON keys")
    func runtimeBridgeRequestBody() async throws {
        let recordedBody = Mutex<Data?>(nil)
        BridgeURLProtocol.handler.withLock {
            $0 = { request in
                let body = try #require(request.bodyData)
                recordedBody.withLock { $0 = body }
                return (
                    HTTPURLResponse(
                        url: try #require(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data()
                )
            }
        }
        defer {
            BridgeURLProtocol.handler.withLock { $0 = nil }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BridgeURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }

        try await withDependencies {
            $0.urlSession = urlSession
        } operation: {
            try await SidecarBridgeClient.liveValue.sendMessage(
                SidecarBridgeClient.RuntimeMessageRequest(
                    agentType: "codex",
                    cwd: "/tmp/workspace-1",
                    message: "Run the tests.",
                    model: "gpt-5.5",
                    sessionID: "session-1",
                    workspaceID: "workspace-1"
                )
            )
        }

        let body = try #require(recordedBody.withLock { $0 })
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        #expect(
            object == [
                "agentType": "codex",
                "cwd": "/tmp/workspace-1",
                "message": "Run the tests.",
                "model": "gpt-5.5",
                "sessionId": "session-1",
                "workspaceId": "workspace-1",
            ]
        )
    }
}

private final class BridgeURLProtocol: URLProtocol, @unchecked Sendable {
    static let handler = Mutex<(@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let handler = try #require(Self.handler.withLock { $0 })
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { }
}

private extension URLRequest {
    var bodyData: Data? {
        if let httpBody {
            return httpBody
        }
        guard let httpBodyStream else {
            return nil
        }

        httpBodyStream.open()
        defer { httpBodyStream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = httpBodyStream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else {
                return nil
            }
            guard count > 0 else {
                return body
            }
            body.append(contentsOf: buffer[..<count])
        }
    }
}
