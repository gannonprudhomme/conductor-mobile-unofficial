//
//  URLCacheClient.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/11/26.
//

import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
public struct URLCacheClient: Sendable {
    public var cachedResponse: @Sendable (URLRequest) -> CachedURLResponse? = { _ in nil }
    public var storeCachedResponse: @Sendable (CachedURLResponse, URLRequest) -> Void
}

extension URLCacheClient: DependencyKey {
    public static var liveValue: Self {
        Self(
            cachedResponse: { URLCache.shared.cachedResponse(for: $0) },
            storeCachedResponse: { URLCache.shared.storeCachedResponse($0, for: $1) }
        )
    }
}

public extension DependencyValues {
    var urlCacheClient: URLCacheClient {
        get { self[URLCacheClient.self] }
        set { self[URLCacheClient.self] = newValue }
    }
}
