//
//  CachedAsyncImage.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/11/26.
//

import Dependencies
import Foundation
import SwiftUI

public struct CachedAsyncImage<Content: View>: View {
    @State private var phase: AsyncImagePhase = .empty

    private let url: URL?
    private let scale: CGFloat
    private let revalidatesCachedResponse: Bool
    private let retryDelays: [Duration]
    private let transaction: Transaction
    private let prepareImage: (UIImage) async -> UIImage?
    private let content: (AsyncImagePhase) -> Content

    public init(
        url: URL?,
        scale: CGFloat = 1,
        revalidatesCachedResponse: Bool = false,
        retryDelays: [Duration] = [],
        transaction: Transaction = Transaction(),
        prepareImage: @escaping (UIImage) async -> UIImage? = { $0 },
        @ViewBuilder content: @escaping (AsyncImagePhase) -> Content
    ) {
        self.url = url
        self.scale = scale
        self.revalidatesCachedResponse = revalidatesCachedResponse
        self.retryDelays = retryDelays
        self.transaction = transaction
        self.prepareImage = prepareImage
        self.content = content
    }

    public var body: some View {
        content(phase)
            .task(id: url) {
                await task()
            }
    }

    private func task() async {
        phase = .empty
        guard let url else {
            return
        }

        do {
            let replacementImage = try await Loader().image(
                for: URLRequest(url: url),
                scale: scale,
                revalidatesCachedResponse: revalidatesCachedResponse,
                retryDelays: retryDelays
            ) { cachedImage in
                guard let image = await prepareImage(cachedImage), !Task.isCancelled else {
                    return false
                }
                withTransaction(transaction) {
                    phase = .success(Image(uiImage: image))
                }
                return true
            } onRetry: {
                guard !Task.isCancelled else {
                    return
                }
                withTransaction(transaction) {
                    phase = .failure(LoadingError.retrying)
                }
            }
            guard let replacementImage else {
                return
            }
            try Task.checkCancellation()
            guard let image = await prepareImage(replacementImage) else {
                throw LoadingError.invalidImageData
            }
            try Task.checkCancellation()

            withTransaction(transaction) {
                phase = .success(Image(uiImage: image))
            }
        } catch is CancellationError {
            return
        } catch where Task.isCancelled {
            return
        } catch {
            guard phase.image == nil else {
                return
            }
            withTransaction(transaction) {
                phase = .failure(error)
            }
        }
    }

    struct Loader {
        @Dependency(\.urlCacheClient) private var urlCacheClient
        @Dependency(\.urlSession) private var urlSession

        func image(
            for request: URLRequest,
            scale: CGFloat,
            revalidatesCachedResponse: Bool,
            retryDelays: [Duration] = [],
            onCachedImage: @MainActor (UIImage) async -> Bool = { _ in false },
            onRetry: @MainActor () -> Void = { }
        ) async throws -> UIImage? {
            let cachedResponse = urlCacheClient.cachedResponse(request)
            let cachedImage = cachedResponse.flatMap {
                UIImage(data: $0.data, scale: scale)
            }
            if let cachedImage, !revalidatesCachedResponse {
                return cachedImage
            }
            let hasPublishedCachedImage = if let cachedImage {
                await onCachedImage(cachedImage)
            } else {
                false
            }
            try Task.checkCancellation()

            var networkRequest = request
            if cachedResponse != nil {
                networkRequest.cachePolicy = .reloadIgnoringLocalCacheData
            }
            if revalidatesCachedResponse, cachedImage != nil,
                let response = cachedResponse?.response as? HTTPURLResponse,
                let eTag = response.value(forHTTPHeaderField: "ETag") {
                networkRequest.setValue(eTag, forHTTPHeaderField: "If-None-Match")
            }

            var retryDelayIterator = retryDelays.makeIterator()
            while !Task.isCancelled {
                do {
                    let replacementImage = try await loadImage(
                        for: networkRequest,
                        cacheRequest: request,
                        hasCachedImage: cachedImage != nil,
                        scale: scale
                    )
                    if let replacementImage {
                        return replacementImage
                    }
                    if hasPublishedCachedImage {
                        return nil
                    }
                    return cachedImage
                } catch {
                    try Task.checkCancellation()
                    guard let retryDelay = retryDelayIterator.next() else {
                        if let cachedImage {
                            if hasPublishedCachedImage {
                                return nil
                            }
                            return cachedImage
                        }
                        throw error
                    }
                    if cachedImage == nil {
                        await onRetry()
                    }
                    try await Task.sleep(for: retryDelay)
                }
            }
            throw CancellationError()
        }

        private func loadImage(
            for request: URLRequest,
            cacheRequest: URLRequest,
            hasCachedImage: Bool,
            scale: CGFloat
        ) async throws -> UIImage? {
            let (data, response) = try await urlSession.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw LoadingError.invalidResponse
            }
            if response.statusCode == 304, hasCachedImage {
                return nil
            }
            guard 200..<300 ~= response.statusCode else {
                throw LoadingError.invalidHTTPStatus(response.statusCode)
            }
            guard let image = UIImage(data: data, scale: scale) else {
                throw LoadingError.invalidImageData
            }

            urlCacheClient.storeCachedResponse(
                CachedURLResponse(response: response, data: data, storagePolicy: .allowed),
                cacheRequest
            )
            return image
        }
    }

    private enum LoadingError: Error {
        case retrying
        case invalidResponse
        case invalidHTTPStatus(Int)
        case invalidImageData
    }
}

public extension CachedAsyncImage {
    init(
        url: URL?,
        scale: CGFloat = 1,
        revalidatesCachedResponse: Bool = false
    ) where Content == Image {
        self.init(
            url: url,
            scale: scale,
            revalidatesCachedResponse: revalidatesCachedResponse
        ) { phase in
            phase.image ?? Image(uiImage: UIImage())
        }
    }

    init<I: View, P: View>(
        url: URL?,
        scale: CGFloat = 1,
        revalidatesCachedResponse: Bool = false,
        @ViewBuilder content: @escaping (Image) -> I,
        @ViewBuilder placeholder: @escaping () -> P
    ) where Content == _ConditionalContent<I, P> {
        self.init(
            url: url,
            scale: scale,
            revalidatesCachedResponse: revalidatesCachedResponse
        ) { phase in
            if let image = phase.image {
                content(image)
            } else {
                placeholder()
            }
        }
    }
}
