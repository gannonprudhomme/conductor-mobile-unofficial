//
//  CachedAsyncImage.swift
//  ConductorModules
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
    private let transaction: Transaction
    private let content: (AsyncImagePhase) -> Content

    public init(
        url: URL?,
        scale: CGFloat = 1,
        transaction: Transaction = Transaction(),
        @ViewBuilder content: @escaping (AsyncImagePhase) -> Content
    ) {
        self.url = url
        self.scale = scale
        self.transaction = transaction
        self.content = content
    }

    public var body: some View {
        content(phase)
            .task(id: url) { await task() }
    }

    private func task() async {
        phase = .empty
        guard let url else { return }

        do {
            let data = try await Loader().data(
                for: URLRequest(url: url)
            )
            try Task.checkCancellation()
            guard let image = UIImage(data: data, scale: scale) else {
                throw LoadingError.invalidImageData
            }

            withTransaction(transaction) {
                phase = .success(Image(uiImage: image))
            }
        } catch is CancellationError {
            return
        } catch where Task.isCancelled {
            return
        } catch {
            withTransaction(transaction) {
                phase = .failure(error)
            }
        }
    }

    private struct Loader {
        @Dependency(\.urlCacheClient) private var urlCacheClient
        @Dependency(\.urlSession) private var urlSession

        func data(for request: URLRequest) async throws -> Data {
            if let response = urlCacheClient.cachedResponse(request) {
                return response.data
            }

            let (data, response) = try await urlSession.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw LoadingError.invalidResponse
            }
            guard 200..<300 ~= response.statusCode else {
                throw LoadingError.invalidHTTPStatus(response.statusCode)
            }

            urlCacheClient.storeCachedResponse(
                CachedURLResponse(response: response, data: data, storagePolicy: .allowed),
                request
            )
            return data
        }
    }

    private enum LoadingError: Error {
        case invalidResponse
        case invalidHTTPStatus(Int)
        case invalidImageData
    }
}

public extension CachedAsyncImage {
    init(url: URL?, scale: CGFloat = 1) where Content == Image {
        self.init(url: url, scale: scale) { phase in
            phase.image ?? Image(uiImage: UIImage())
        }
    }

    init<I: View, P: View>(
        url: URL?,
        scale: CGFloat = 1,
        @ViewBuilder content: @escaping (Image) -> I,
        @ViewBuilder placeholder: @escaping () -> P
    ) where Content == _ConditionalContent<I, P> {
        self.init(url: url, scale: scale) { phase in
            if let image = phase.image {
                content(image)
            } else {
                placeholder()
            }
        }
    }
}
