//
//  CachedAsyncImageTests.swift
//  ConductorDesignTests
//
//  Created by Gannon Prudomme on 7/11/26.
//

import Dependencies
import CustomDump
import Foundation
import SwiftUI
@testable import ConductorDesign
import Testing
import UIKit

@Suite(.serialized)
struct CachedAsyncImageTests {
    @MainActor
    @Test("API matches AsyncImage's URL initializers")
    func initializers() {
        _ = CachedAsyncImage(url: nil)
        _ = CachedAsyncImage(url: nil) { image in
            image
        } placeholder: {
            Color.clear
        }
        _ = CachedAsyncImage(url: nil, transaction: Transaction()) { _ in
            Color.clear
        }
        _ = CachedAsyncImage(url: nil, revalidatesCachedResponse: true)
        _ = CachedAsyncImage(url: nil, prepareImage: { _ in nil }) { _ in
            Color.clear
        }
    }

    @Test("The live cache client stores and retrieves responses")
    func liveCacheClient() {
        let request = URLRequest(
            url: URL(string: "https://example.com/cached-async-image-test.png")!
        )
        let expectedData = Data("cached".utf8)
        let client = URLCacheClient.liveValue
        URLCache.shared.removeCachedResponse(for: request)
        defer { URLCache.shared.removeCachedResponse(for: request) }

        client.storeCachedResponse(
            CachedURLResponse(
                response: HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                data: expectedData
            ),
            request
        )

        expectNoDifference(client.cachedResponse(request)?.data, expectedData)
    }

    @MainActor
    @Test("Revalidation returns a valid cached image when the server reports no change")
    func revalidation() async throws {
        let url = URL(string: "https://example.com/favicon.png")!
        let request = URLRequest(url: url)
        let imageData = try testImageData()
        let cachedResponse = CachedURLResponse(
            response: HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["ETag": "\"favicon-1\""]
            )!,
            data: imageData
        )
        let session = testURLSession()
        ImageURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"favicon-1\"")
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 304,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        defer { ImageURLProtocol.handler = nil }

        let image = try await withDependencies {
            $0.urlCacheClient = URLCacheClient(
                cachedResponse: { _ in cachedResponse },
                storeCachedResponse: { _, _ in
                    Issue.record("A 304 response should keep the existing cached response")
                }
            )
            $0.urlSession = session
        } operation: {
            try await CachedAsyncImage<EmptyView>.Loader().image(
                for: request,
                scale: 1,
                revalidatesCachedResponse: true
            )
        }

        #expect(image.size == CGSize(width: 1, height: 1))
    }

    @MainActor
    @Test("A valid cached image avoids the network")
    func cacheHit() async throws {
        let url = URL(string: "https://example.com/avatar.png")!
        let request = URLRequest(url: url)
        let imageData = try testImageData()
        let cachedResponse = CachedURLResponse(
            response: HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!,
            data: imageData
        )
        ImageURLProtocol.handler = { _ in
            Issue.record("A valid cache hit should not make a network request")
            return (
                HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { ImageURLProtocol.handler = nil }

        let image = try await withDependencies {
            $0.urlCacheClient = URLCacheClient(
                cachedResponse: { _ in cachedResponse },
                storeCachedResponse: { _, _ in }
            )
            $0.urlSession = testURLSession()
        } operation: {
            try await CachedAsyncImage<EmptyView>.Loader().image(
                for: request,
                scale: 1,
                revalidatesCachedResponse: false
            )
        }

        #expect(image.size == CGSize(width: 1, height: 1))
    }

    @MainActor
    @Test("Invalid cached data is replaced with a valid network image")
    func invalidCache() async throws {
        let url = URL(string: "https://example.com/avatar.png")!
        let request = URLRequest(url: url)
        let imageData = try testImageData()
        let invalidResponse = CachedURLResponse(
            response: HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!,
            data: Data("invalid".utf8)
        )
        ImageURLProtocol.handler = { request in
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                imageData
            )
        }
        defer { ImageURLProtocol.handler = nil }

        let image = try await withDependencies {
            $0.urlCacheClient = URLCacheClient(
                cachedResponse: { _ in invalidResponse },
                storeCachedResponse: { response, _ in
                    #expect(response.data == imageData)
                }
            )
            $0.urlSession = testURLSession()
        } operation: {
            try await CachedAsyncImage<EmptyView>.Loader().image(
                for: request,
                scale: 1,
                revalidatesCachedResponse: false
            )
        }

        #expect(image.size == CGSize(width: 1, height: 1))
    }
}

@MainActor
private func testImageData() throws -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return try #require(
        UIGraphicsImageRenderer(
            size: CGSize(width: 1, height: 1),
            format: format
        )
            .image { _ in }
            .pngData()
    )
}

private func testURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.protocolClasses = [ImageURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class ImageURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            Issue.record("Image URL protocol started without a handler")
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
