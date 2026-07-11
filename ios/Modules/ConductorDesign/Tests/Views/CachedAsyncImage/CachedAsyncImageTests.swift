//
//  CachedAsyncImageTests.swift
//  ConductorDesignTests
//
//  Created by Gannon Prudomme on 7/11/26.
//

import CustomDump
import Foundation
import SwiftUI
@testable import ConductorDesign
import Testing

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
}
