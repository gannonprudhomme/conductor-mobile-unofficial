//
//  DesktopClient+WebSockets.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/13/26.
//

import AsyncAlgorithms
import Dependencies
import Foundation
import Observation
import SharedConductorData
import Sharing

extension DesktopClient {
    /// Builds the workspace-list socket URL used by `observeWorkspaces`.
    static func workspacesWebSocketURL(serverAddress: String) -> URL? {
        serverURL(scheme: "ws", address: serverAddress)?
            .appending(path: "workspaces")
    }

    static let maximumWebSocketMessageSize = 64 * 1_024 * 1_024

    /// Builds the message WebSocket URL, optionally resuming after one opaque history ID.
    ///
    /// `messageObservationStream` passes the cursor from the same cached snapshot it displays.
    /// `URLQueryItem` percent-encodes the raw identifier without treating it as a path component.
    static func messagesWebSocketURL(
        serverAddress: String,
        workspaceID: String,
        sessionID: String,
        resumeAfterMessageID: Message.ID? = nil
    ) -> URL? {
        guard let url = serverURL(scheme: "ws", address: serverAddress)?
            .appending(path: "workspaces")
            .appending(path: workspaceID)
            .appending(path: "sessions")
            .appending(path: sessionID)
            .appending(path: "messages") else {
            return nil
        }
        guard let resumeAfterMessageID,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.queryItems = [
            URLQueryItem(name: "after", value: resumeAfterMessageID)
        ]
        return components.url
    }

    /// Builds the session-list socket URL used by `observeSessions`.
    static func sessionsWebSocketURL(serverAddress: String, workspaceID: String) -> URL? {
        serverURL(scheme: "ws", address: serverAddress)?
            .appending(path: "workspaces")
            .appending(path: workspaceID)
            .appending(path: "sessions")
    }

    /// Automatically reacts to changes in the server address.
    ///
    /// `bufferingPolicy` controls which values wait when the producer is faster than the
    /// consumer. State snapshots keep only the newest pending value by default; callers whose
    /// values are incremental can opt into an unbounded buffer so no update is discarded.
    static func observe<Value: Decodable & Sendable>(
        _ type: Value.Type,
        bufferingPolicy: AsyncThrowingStream<
            Value,
            any Error
        >.Continuation.BufferingPolicy = .bufferingNewest(1),
        at makeURL: @escaping @Sendable (String) -> URL?
    ) -> AsyncThrowingStream<Value, any Error> {
        @Dependency(\.urlSession) var urlSession
        @Shared(.desktopServerAddress) var desktopServerAddress

        // Capture the shared value's projection so `Observations` can track the current address
        // and every persisted change without making feature consumers manage reconnections.
        let sharedServerAddress = $desktopServerAddress

        let values = Observations { sharedServerAddress.wrappedValue }
            .map { DesktopLeaseAuthority.shared.transition(to: $0) }
            .removeDuplicates()
            .flatMapLatest { lifecycle -> AsyncThrowingStream<Value, any Error> in
                guard case let .configured(endpoint, _) = lifecycle,
                      let url = makeURL(endpoint.canonicalAddress) else {
                    return AsyncThrowingStream { continuation in
                        continuation.finish(
                            throwing: DesktopClientError.invalidServerAddress
                        )
                    }
                }

                return webSocketStream(
                    type,
                    bufferingPolicy: bufferingPolicy,
                    using: WebSocketTaskClient(
                        url: url,
                        configuration: localNetworkConfiguration(
                            from: urlSession.configuration
                        )
                    )
                )
            }

        // The operators above return an opaque `some AsyncSequence`, while `DesktopClient`'s
        // dependency endpoints promise a concrete `AsyncThrowingStream`. This outer stream is
        // the type-erasure bridge between them. It also forwards consumer cancellation to the
        // task driving the operator chain.
        return AsyncThrowingStream(bufferingPolicy: bufferingPolicy) { continuation in
            let producer = Task {
                do {
                    for try await value in values {
                        if case .terminated = continuation.yield(value) {
                            return
                        }
                    }
                } catch {
                    guard !Task.isCancelled else {
                        return
                    }

                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    /// Observes one desktop transcript across persisted server-address changes.
    ///
    /// Unlike workspace/session observations, message frames after the initial response are
    /// incremental and therefore use an unbounded buffer. Address changes replace the socket while
    /// the existing durable transcript remains available as the single paired desktop's cache.
    static func observeMessages(
        workspaceID: Workspace.ID,
        sessionID: Session.ID
    ) -> AsyncThrowingStream<DesktopMessageObservation, any Error> {
        @Shared(.desktopServerAddress) var desktopServerAddress
        let sharedServerAddress = $desktopServerAddress
        let values = Observations { sharedServerAddress.wrappedValue }
            .map { DesktopLeaseAuthority.shared.transition(to: $0) }
            .removeDuplicates()
            .flatMapLatest { lifecycle in
                messageObservationStream(
                    lifecycle: lifecycle,
                    workspaceID: workspaceID,
                    sessionID: sessionID
                )
            }

        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let producer = Task {
                do {
                    for try await value in values {
                        if case .terminated = continuation.yield(value) {
                            return
                        }
                    }
                } catch {
                    guard !Task.isCancelled else {
                        return
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    /// Observes raw desktop message envelopes without requiring a local desktop session baseline.
    ///
    /// Cloud chats use this stream only for the mutable queue. Their completed transcript and
    /// canonical session belong to the Cloud cache, so the desktop transcript store cannot own
    /// or resume that raw session.
    static func observeMessageEvents(
        workspaceID: Workspace.ID,
        sessionID: Session.ID
    ) -> AsyncThrowingStream<MessageSyncEvent, any Error> {
        observe(
            MessageSyncEvent.self,
            bufferingPolicy: .unbounded
        ) { serverAddress in
            messagesWebSocketURL(
                serverAddress: serverAddress,
                workspaceID: workspaceID,
                sessionID: sessionID
            )
        }
    }

    /// Runs the cache/resume lifecycle for one endpoint identity emitted by `observeMessages`.
    ///
    /// It acquires a connection lease before reading the cache, emits a durable snapshot
    /// immediately, then resumes from that exact snapshot's cursor. Each received event is
    /// committed before it reaches Chat, so database observation remains the UI source of truth.
    private static func messageObservationStream(
        lifecycle: DesktopEndpointLifecycle,
        workspaceID: Workspace.ID,
        sessionID: Session.ID
    ) -> AsyncThrowingStream<DesktopMessageObservation, any Error> {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.urlSession) var urlSession
        let databaseWriter = database
        let urlSessionConfiguration = urlSession.configuration
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let producer = Task {
                guard case let .configured(endpoint, endpointEpoch) = lifecycle else {
                    continuation.finish()
                    return
                }

                let resumeKey = ResumeKey(
                    workspaceID: workspaceID,
                    sessionID: sessionID
                )
                do {
                    // Beginning the replacement connection first invalidates any older generation.
                    // That older socket therefore cannot advance the cache between this read and
                    // the `after` value derived from the same snapshot.
                    guard let lease = DesktopLeaseAuthority.shared.beginConnection(
                        resumeKey: resumeKey,
                        endpointEpoch: endpointEpoch
                    ) else {
                        continuation.finish()
                        return
                    }

                    let cachedTranscriptSnapshot = try await DesktopTranscriptStore
                        .cachedTranscriptSnapshot(
                            workspaceID: workspaceID,
                            sessionID: sessionID,
                            database: databaseWriter
                        )
                    if let cachedTranscriptSnapshot {
                        continuation.yield(.persisted(cachedTranscriptSnapshot))
                    }

                    var resumeCursor = cachedTranscriptSnapshot?.cursor
                    reconnectWithoutCursor: while !Task.isCancelled {
                        guard let url = messagesWebSocketURL(
                            serverAddress: endpoint.canonicalAddress,
                            workspaceID: workspaceID,
                            sessionID: sessionID,
                            resumeAfterMessageID: resumeCursor
                        ) else {
                            throw DesktopClientError.invalidServerAddress
                        }
                        let stream = webSocketStream(
                            MessageSyncEvent.self,
                            bufferingPolicy: .unbounded,
                            using: WebSocketTaskClient(
                                url: url,
                                configuration: localNetworkConfiguration(
                                    from: urlSessionConfiguration
                                )
                            )
                        )
                        for try await event in stream {
                            do {
                                let appliedEvent = try await DesktopTranscriptStore
                                    .applySyncEvent(
                                        event,
                                        lease: lease,
                                        database: databaseWriter
                                )
                                resumeCursor = appliedEvent.cursor
                                continuation.yield(.persisted(appliedEvent))
                            } catch DesktopTranscriptStore.ApplyError.incompleteBaseline {
                                // A stale/missing baseline cannot safely accept a suffix. Reopen
                                // without `after`; the server then sends a complete replacement.
                                resumeCursor = nil
                                continue reconnectWithoutCursor
                            } catch DesktopTranscriptStore.ApplyError.missingSession {
                                continuation.finish()
                                return
                            } catch DesktopTranscriptStore.ApplyError.staleLease {
                                continuation.finish()
                                return
                            }
                        }
                        continuation.finish()
                        return
                    }
                } catch {
                    guard !Task.isCancelled else {
                        return
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    /// Converts one callback-style WebSocket task into the async stream used by every observer.
    ///
    /// This stays internal so transport tests can inject `WebSocketTaskClient`; production callers
    /// use `observe` or `messageObservationStream` instead.
    static func webSocketStream<Value: Decodable & Sendable>(
        _ type: Value.Type,
        bufferingPolicy: AsyncThrowingStream<
            Value,
            any Error
        >.Continuation.BufferingPolicy = .bufferingNewest(1),
        using task: WebSocketTaskClient
    ) -> AsyncThrowingStream<Value, any Error> {
        @Shared(.desktopConnectionStatus) var connectionStatus
        let sharedConnectionStatus = $connectionStatus

        sharedConnectionStatus.withLock {
            if $0 != .connected {
                $0 = .connecting
            }
        }

        return AsyncThrowingStream(bufferingPolicy: bufferingPolicy) { continuation in
            task.resume()
            let producer = Task {
                // A producer can fail before its termination handler is installed. In that case,
                // `finish` does not invoke the handler later, so the producer closes the socket.
                defer {
                    if !Task.isCancelled {
                        task.cancel()
                    }
                }

                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        guard !Task.isCancelled else {
                            return
                        }

                        sharedConnectionStatus.withLock { $0 = .connected }
                        let data = try data(from: message)
                        let value = try JSONDecoder.conductor.decode(type, from: data)

                        if case .terminated = continuation.yield(value) {
                            return
                        }
                    }
                } catch {
                    guard !Task.isCancelled else {
                        return
                    }

                    if DesktopClientError.isConnectionFailure(error) {
                        sharedConnectionStatus.withLock { $0 = .disconnected }
                    }
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                producer.cancel()
                task.cancel()
            }
        }
    }

    // Really just a protocol/mock surface over `URLSessionWebSocketTask`
    struct WebSocketTaskClient: Sendable {
        fileprivate var cancel: @Sendable () -> Void
        fileprivate var receive: @Sendable () async throws -> URLSessionWebSocketTask.Message
        fileprivate var resume: @Sendable () -> Void

        /// Wraps an existing Foundation task when its owning session is managed elsewhere.
        init(_ task: URLSessionWebSocketTask) {
            task.maximumMessageSize = DesktopClient.maximumWebSocketMessageSize
            self.cancel = {
                task.cancel(with: .goingAway, reason: nil)
            }
            self.receive = {
                try await task.receive()
            }
            self.resume = {
                task.resume()
            }
        }

        /// Creates the production task and retains its session for the socket's full lifetime.
        init(url: URL, configuration: URLSessionConfiguration) {
            let session = URLSession(configuration: configuration)
            let task = session.webSocketTask(with: url)
            task.maximumMessageSize = DesktopClient.maximumWebSocketMessageSize
            self.cancel = {
                task.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
            }
            self.receive = {
                try await task.receive()
            }
            self.resume = {
                task.resume()
            }
        }

        /// Supplies deterministic transport operations to `webSocketStream` tests.
        init(
            cancel: @escaping @Sendable () -> Void,
            receive: @escaping @Sendable () async throws -> URLSessionWebSocketTask.Message,
            resume: @escaping @Sendable () -> Void
        ) {
            self.cancel = cancel
            self.receive = receive
            self.resume = resume
        }
    }
}

fileprivate extension DesktopClient {
    /// Normalizes Foundation's binary/text WebSocket frames before JSON decoding.
    static func data(from message: URLSessionWebSocketTask.Message) throws -> Data {
        switch message {
        case let .data(data):
            data

        case let .string(string):
            Data(string.utf8)

        @unknown default:
            throw DesktopClientError.invalidResponse
        }
    }
}
