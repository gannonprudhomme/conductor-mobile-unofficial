//
//  CachedAsyncImageTests.swift
//  ConductorDesignTests
//
//  Created by Gannon Prudomme on 7/11/26.
//

import Dependencies
import CustomDump
import Foundation
import Synchronization
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
    @Test("A cached image remains displayed when revalidation reports no change")
    func revalidation() async throws {
        let url = URL(string: "https://example.com/favicon.png")!
        let request = URLRequest(url: url)
        let imageData = try testImageData()
        let displayedImageSizes = Mutex<[CGSize]>([])
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
            #expect(displayedImageSizes.withLock { $0 } == [CGSize(width: 1, height: 1)])
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

        let replacementImage = try await withDependencies {
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
            ) { cachedImage in
                displayedImageSizes.withLock { $0.append(cachedImage.size) }
                return true
            } onRetry: {
                Issue.record("Cached image revalidation should not expose a retrying phase")
            }
        }

        #expect(displayedImageSizes.withLock { $0 } == [CGSize(width: 1, height: 1)])
        #expect(replacementImage == nil)
    }

    @MainActor
    @Test("An unpublished cached image is returned when revalidation reports no change")
    func failedCachedImagePreparation() async throws {
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
        ImageURLProtocol.handler = { _ in
            (
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

        let replacementImage = try await withDependencies {
            $0.urlCacheClient = URLCacheClient(
                cachedResponse: { _ in cachedResponse },
                storeCachedResponse: { _, _ in
                    Issue.record("A 304 response should keep the existing cached response")
                }
            )
            $0.urlSession = testURLSession()
        } operation: {
            try await CachedAsyncImage<EmptyView>.Loader().image(
                for: request,
                scale: 1,
                revalidatesCachedResponse: true
            ) { _ in
                false
            }
        }

        let image = try #require(replacementImage)
        #expect(image.size == CGSize(width: 1, height: 1))
    }

    @MainActor
    @Test("A successful revalidation replaces the displayed cached image")
    func successfulRefresh() async throws {
        let url = URL(string: "https://example.com/favicon.png")!
        let request = URLRequest(url: url)
        let cachedImageData = try testImageData()
        let refreshedImageData = try testImageData(size: CGSize(width: 2, height: 2))
        let displayedImageSizes = Mutex<[CGSize]>([])
        let cachedResponse = CachedURLResponse(
            response: HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["ETag": "\"favicon-1\""]
            )!,
            data: cachedImageData
        )
        ImageURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"favicon-1\"")
            #expect(displayedImageSizes.withLock { $0 } == [CGSize(width: 1, height: 1)])
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["ETag": "\"favicon-2\""]
                )!,
                refreshedImageData
            )
        }
        defer { ImageURLProtocol.handler = nil }

        let loadedImage = try await withDependencies {
            $0.urlCacheClient = URLCacheClient(
                cachedResponse: { _ in cachedResponse },
                storeCachedResponse: { response, _ in
                    #expect(response.data == refreshedImageData)
                }
            )
            $0.urlSession = testURLSession()
        } operation: {
            try await CachedAsyncImage<EmptyView>.Loader().image(
                for: request,
                scale: 1,
                revalidatesCachedResponse: true
            ) { cachedImage in
                displayedImageSizes.withLock { $0.append(cachedImage.size) }
                return true
            }
        }

        let image = try #require(loadedImage)
        #expect(displayedImageSizes.withLock { $0 } == [CGSize(width: 1, height: 1)])
        #expect(image.size == CGSize(width: 2, height: 2))
    }

    @MainActor
    @Test("A cached image remains displayed when revalidation fails")
    func failedRefresh() async throws {
        let url = URL(string: "https://example.com/favicon.png")!
        let request = URLRequest(url: url)
        let imageData = try testImageData()
        let displayedImageSizes = Mutex<[CGSize]>([])
        let requestCount = Mutex(0)
        let cachedResponse = CachedURLResponse(
            response: HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["ETag": "\"favicon-1\""]
            )!,
            data: imageData
        )
        ImageURLProtocol.handler = { _ in
            requestCount.withLock { $0 += 1 }
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        defer { ImageURLProtocol.handler = nil }

        let replacementImage = try await withDependencies {
            $0.urlCacheClient = URLCacheClient(
                cachedResponse: { _ in cachedResponse },
                storeCachedResponse: { _, _ in
                    Issue.record("A failed refresh should not replace the cached response")
                }
            )
            $0.urlSession = testURLSession()
        } operation: {
            try await CachedAsyncImage<EmptyView>.Loader().image(
                for: request,
                scale: 1,
                revalidatesCachedResponse: true,
                retryDelays: [.milliseconds(1)]
            ) { cachedImage in
                displayedImageSizes.withLock { $0.append(cachedImage.size) }
                return true
            } onRetry: {
                Issue.record("A cached image should remain displayed while refresh retries")
            }
        }

        #expect(requestCount.withLock { $0 } == 2)
        #expect(displayedImageSizes.withLock { $0 } == [CGSize(width: 1, height: 1)])
        #expect(replacementImage == nil)
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

        let loadedImage = try await withDependencies {
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

        let image = try #require(loadedImage)
        #expect(image.size == CGSize(width: 1, height: 1))
    }

    @MainActor
    @Test("A transient image failure is retried")
    func retry() async throws {
        let url = URL(string: "https://example.com/favicon.png")!
        let request = URLRequest(url: url)
        let imageData = try testImageData()
        let requestCount = Mutex(0)
        let retryCount = Mutex(0)
        ImageURLProtocol.handler = { _ in
            let attempt = requestCount.withLock {
                $0 += 1
                return $0
            }
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: attempt == 1 ? 404 : 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                attempt == 1 ? Data() : imageData
            )
        }
        defer { ImageURLProtocol.handler = nil }

        let loadedImage = try await withDependencies {
            $0.urlCacheClient = URLCacheClient(
                cachedResponse: { _ in nil },
                storeCachedResponse: { _, _ in }
            )
            $0.urlSession = testURLSession()
        } operation: {
            try await CachedAsyncImage<EmptyView>.Loader().image(
                for: request,
                scale: 1,
                revalidatesCachedResponse: false,
                retryDelays: [.milliseconds(1)]
            ) { _ in
                Issue.record("An uncached request should not display a cached image")
                return false
            } onRetry: {
                retryCount.withLock { $0 += 1 }
            }
        }

        let image = try #require(loadedImage)
        #expect(requestCount.withLock { $0 } == 2)
        #expect(retryCount.withLock { $0 } == 1)
        #expect(image.size == CGSize(width: 1, height: 1))
    }

    @MainActor
    @Test("Canceling a load does not publish a retry")
    func cancellation() async {
        let url = URL(string: "https://example.com/favicon.png")!
        let request = URLRequest(url: url)
        let hasRequestStarted = Mutex(false)
        let retryCount = Mutex(0)
        func hasNetworkRequestStarted() -> Bool {
            hasRequestStarted.withLock { $0 }
        }
        ImageURLProtocol.handler = { _ in
            hasRequestStarted.withLock { $0 = true }
            return nil
        }
        defer { ImageURLProtocol.handler = nil }

        let loadTask = Task {
            try await withDependencies {
                $0.urlCacheClient = URLCacheClient(
                    cachedResponse: { _ in nil },
                    storeCachedResponse: { _, _ in }
                )
                $0.urlSession = testURLSession()
            } operation: {
                try await CachedAsyncImage<EmptyView>.Loader().image(
                    for: request,
                    scale: 1,
                    revalidatesCachedResponse: false,
                    retryDelays: [.milliseconds(1)]
                ) { _ in
                    Issue.record("An uncached request should not display a cached image")
                    return false
                } onRetry: {
                    retryCount.withLock { $0 += 1 }
                }
            }
        }
        while !hasNetworkRequestStarted() {
            await Task.yield()
        }
        loadTask.cancel()

        await #expect(throws: CancellationError.self) {
            try await loadTask.value
        }
        #expect(retryCount.withLock { $0 } == 0)
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

        let loadedImage = try await withDependencies {
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

        let image = try #require(loadedImage)
        #expect(image.size == CGSize(width: 1, height: 1))
    }
}

@MainActor
private func testImageData(
    size: CGSize = CGSize(width: 1, height: 1)
) throws -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return try #require(
        UIGraphicsImageRenderer(
            size: size,
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
    nonisolated(unsafe) static var handler: (
        @Sendable (URLRequest) -> (HTTPURLResponse, Data)?
    )?

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
        guard let (response, data) = handler(request) else {
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
