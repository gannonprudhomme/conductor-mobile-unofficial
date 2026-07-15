//
//  DesktopClientTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

@testable import ConductorMobileData
import CustomDump
import Dependencies
import Foundation
import Sharing
import SharedConductorData
import Testing

@Suite(.serialized)
struct DesktopClientTests {
    @Test("Sending a message returns the canonical database row")
    func sendMessage() async throws {
        let message = Message(
            id: "message-1",
            sessionID: "session-1",
            role: .user,
            content: "Run the tests.",
            createdAt: Date(timeIntervalSince1970: 1_783_555_200),
            turnID: "turn-1"
        )
        let recordedRequest = LockIsolated<URLRequest?>(nil)
        DesktopClientURLProtocol.handler.setValue { request in
            recordedRequest.setValue(request)
            return (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try JSONEncoder.conductor.encode(message)
            )
        }
        defer { DesktopClientURLProtocol.handler.setValue(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DesktopClientURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }

        let response = try await withDependencies {
            $0.urlSession = urlSession
        } operation: {
            try await DesktopClient.liveValue.sendMessage(
                workspaceID: "workspace-1",
                sessionID: "session-1",
                message: "Run the tests."
            )
        }

        expectNoDifference(response, message)
        let request = try #require(recordedRequest.value)
        expectNoDifference(
            request.url?.path,
            "/workspaces/workspace-1/sessions/session-1/messages"
        )
        let body = try #require(request.bodyData)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        expectNoDifference(
            object,
            ["message": "Run the tests."]
        )
    }

    @Test("Sending supports a legacy no-content response")
    func sendMessageLegacyResponse() async throws {
        DesktopClientURLProtocol.handler.setValue { request in
            (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        defer { DesktopClientURLProtocol.handler.setValue(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DesktopClientURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }

        let response = try await withDependencies {
            $0.urlSession = urlSession
        } operation: {
            try await DesktopClient.liveValue.sendMessage(
                workspaceID: "workspace-1",
                sessionID: "session-1",
                message: "Run the tests."
            )
        }

        #expect(response == nil)
    }

    @Test("Stopping a session returns its canonical database row")
    func stopSession() async throws {
        let session = Session.preview(
            updatedAt: "2026-07-09T00:00:01Z",
            status: .idle
        )
        let recordedRequest = LockIsolated<URLRequest?>(nil)
        DesktopClientURLProtocol.handler.setValue { request in
            recordedRequest.setValue(request)
            return (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try JSONEncoder.conductor.encode(session)
            )
        }
        defer { DesktopClientURLProtocol.handler.setValue(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DesktopClientURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }

        let response = try await withDependencies {
            $0.urlSession = urlSession
        } operation: {
            try await DesktopClient.liveValue.stopSession(
                workspaceID: "workspace-1",
                sessionID: "session-1"
            )
        }

        expectNoDifference(response, session)
        let request = try #require(recordedRequest.value)
        expectNoDifference(
            request.url?.path,
            "/workspaces/workspace-1/sessions/session-1/stop"
        )
        let body = try #require(request.bodyData)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        expectNoDifference(object, [:])
    }

    @Test("Stopping supports a legacy no-content response")
    func stopSessionLegacyResponse() async throws {
        DesktopClientURLProtocol.handler.setValue { request in
            (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        defer { DesktopClientURLProtocol.handler.setValue(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DesktopClientURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }

        let response = try await withDependencies {
            $0.urlSession = urlSession
        } operation: {
            try await DesktopClient.liveValue.stopSession(
                workspaceID: "workspace-1",
                sessionID: "session-1"
            )
        }

        #expect(response == nil)
    }

    @Test("Desktop client errors include response details")
    func errorDescriptions() {
        #expect(
            DesktopClientError.requestFailed(statusCode: 500, message: "boom").localizedDescription
                == "The desktop service returned HTTP 500: boom"
        )

        #expect(
            DesktopClientError.requestFailed(statusCode: 404, message: "").localizedDescription
                == "The desktop service returned HTTP 404."
        )
    }

    @Test("Conductor decoder accepts SQLite and ISO 8601 dates")
    func dateDecoding() throws {
        let dates = try JSONDecoder.conductor.decode(
            [Date].self,
            from: Data(
                """
                [
                  "2026-07-09 00:00:00",
                  "2026-07-09T00:00:00Z",
                  "2026-07-09T00:00:00.000Z"
                ]
                """.utf8
            )
        )

        expectNoDifference(
            dates,
            Array(repeating: Date(timeIntervalSince1970: 1_783_555_200), count: 3)
        )
    }

    @Test("Repository icon URLs use the desktop icon endpoint")
    func repositoryIconURL() {
        withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.desktopServerAddress) var desktopServerAddress
            let repository = Repository(
                id: "repository-1",
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)
            )

            expectNoDifference(
                DesktopClient.repositoryIconURL(for: repository).absoluteString,
                "http://192.168.0.32:3768/repositories/repository-1/icon"
            )

            $desktopServerAddress.withLock { $0 = "my-mac" }

            expectNoDifference(
                DesktopClient.repositoryIconURL(for: repository).absoluteString,
                "http://my-mac:3768/repositories/repository-1/icon"
            )

            $desktopServerAddress.withLock { $0 = "my-mac:4000" }

            expectNoDifference(
                DesktopClient.repositoryIconURL(for: repository).absoluteString,
                "http://my-mac:4000/repositories/repository-1/icon"
            )
        }
    }
}

private final class DesktopClientURLProtocol: URLProtocol, @unchecked Sendable {
    static let handler = LockIsolated<
        (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    >(nil)

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let handler = try #require(Self.handler.value)
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
        var count: Int
        repeat {
            count = httpBodyStream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else {
                return nil
            }
            body.append(contentsOf: buffer[..<count])
        } while count > 0
        return body
    }
}
