//
//  DesktopEndpoint.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/28/26.
//

import Foundation
import SharedConductorData

/// A validated desktop service address.
///
/// Settings stores user-entered `host[:port]` text. `DesktopClient` canonicalizes that value so
/// spelling-only changes do not unnecessarily restart requests or observations.
struct DesktopEndpoint: Equatable, Sendable {
    /// Canonical `host:port` used to build request and WebSocket URLs.
    let canonicalAddress: String

    /// Validates and canonicalizes a settings address that intentionally is not a full URL.
    init?(
        rawAddress: String,
        defaultPort: Int = DesktopClient.defaultServerPort
    ) {
        let address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty,
              !address.contains("://"),
              !address.contains("@"),
              !address.contains("/"),
              !address.contains("?"),
              !address.contains("#"),
              var components = URLComponents(string: "http://\(address)"),
              components.scheme == "http",
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil,
              let parsedHost = components.host,
              !parsedHost.isEmpty else {
            return nil
        }
        let port = components.port ?? defaultPort
        guard (1...65_535).contains(port) else {
            return nil
        }

        let host = parsedHost.lowercased(with: Locale(identifier: "en_US_POSIX"))
        components.port = port
        components.host = host
        guard let canonicalAddress = components.string?
            .dropPrefix("http://") else {
            return nil
        }

        self.canonicalAddress = canonicalAddress
    }

    /// Builds an HTTP or WebSocket base URL for this already-validated endpoint.
    func url(scheme: String) -> URL? {
        guard var components = URLComponents(
            string: "http://\(canonicalAddress)"
        ) else {
            return nil
        }
        components.scheme = scheme
        return components.url
    }
}

/// The endpoint state currently driving desktop requests and observations.
///
/// The epoch changes whenever endpoint identity changes so delayed work from a prior address can
/// be rejected without storing the address alongside transcript data.
enum DesktopEndpointLifecycle: Equatable, Sendable {
    /// Settings does not currently contain a usable desktop address.
    case unavailable(endpointEpoch: UInt64)
    /// Requests and observations may use this validated endpoint.
    case configured(endpoint: DesktopEndpoint, endpointEpoch: UInt64)

    /// Monotonic endpoint generation used to reject work started for an older address.
    var endpointEpoch: UInt64 {
        switch self {
        case let .unavailable(endpointEpoch),
             let .configured(_, endpointEpoch):
            endpointEpoch
        }
    }
}

/// The workspace/session identity shared by replacement message connections.
///
/// Raw UTF-8 equality prevents Swift's Unicode canonical equivalence from merging opaque IDs.
struct ResumeKey: Hashable, Sendable {
    let workspaceID: Workspace.ID
    let sessionID: Session.ID

    /// Compares every opaque identity by raw bytes rather than Unicode canonical equivalence.
    static func == (lhs: Self, rhs: Self) -> Bool {
        RawUTF8Key(lhs.workspaceID) == RawUTF8Key(rhs.workspaceID)
            && RawUTF8Key(lhs.sessionID) == RawUTF8Key(rhs.sessionID)
    }

    /// Hashes the same raw-byte identity used by equality so dictionary generations stay distinct.
    func hash(into hasher: inout Hasher) {
        hasher.combine(RawUTF8Key(workspaceID))
        hasher.combine(RawUTF8Key(sessionID))
    }
}

/// Proves that one message WebSocket is the newest generation for a resume key.
///
/// `DesktopTranscriptStore` requires this lease before mutating cached rows. Starting a replacement
/// connection increments the generation, making delayed events from the old socket harmless.
struct ConnectionLease: Equatable, Sendable {
    let resumeKey: ResumeKey
    let generation: UInt64
    let endpointEpoch: UInt64
}

/// Pins a multi-step HTTP workflow to the desktop endpoint on which it began.
///
/// Workspace/session creation can span several requests and database writes. This lease prevents a
/// result returned by an old address from being published after Settings switches desktops.
public struct DesktopRequestLease: Equatable, Sendable {
    public let baseURL: URL
    public let endpointEpoch: UInt64

    /// Records the URL and epoch captured by `DesktopClient.acquireRequestLease`.
    public init(
        baseURL: URL,
        endpointEpoch: UInt64
    ) {
        self.baseURL = baseURL
        self.endpointEpoch = endpointEpoch
    }

    /// Performs synchronous persistence only if this endpoint still owns the current epoch.
    ///
    /// The live `DesktopClient` creation-persistence endpoints call this inside their database
    /// transaction. The authority lock makes endpoint transition and persistence linearizable,
    /// closing the check-then-write race that a separate `isRequestLeaseValid` check would leave.
    public func performIfCurrent<Value>(
        _ operation: () throws -> Value
    ) rethrows -> Value? {
        try DesktopLeaseAuthority.shared.withValidRequestLease(
            self,
            operation: operation
        )
    }
}

/// Carries a request lease through existing `DesktopClient` helpers without adding it to every API.
///
/// `baseURL()` reads this task-local value before each request and rejects it if Settings changed.
public enum DesktopRequestLeaseContext {
    @TaskLocal public static var current: DesktopRequestLease?
}

/// Tells Chat whether an observed envelope already committed to the local database.
public enum DesktopMessageObservation: Equatable, Sendable {
    /// Cached snapshots and server envelopes that have already committed to the local database.
    case persisted(MessageSyncEvent)
    /// Test/mock envelopes that still require Chat to perform the legacy persistence step.
    case requiresPersistence(MessageSyncEvent)

    /// Preserves the pre-resume test/mock API as an explicitly legacy full event.
    public static func snapshot(_ messages: [Message]) -> Self {
        .requiresPersistence(.snapshot(messages))
    }

    /// Preserves the pre-resume test/mock API as an explicitly legacy incremental event.
    public static func changes(
        upserting messages: [Message] = [],
        deleting deletedMessageIDs: [Message.ID] = []
    ) -> Self {
        .requiresPersistence(
            .changes(
                upserting: messages,
                deleting: deletedMessageIDs
            )
        )
    }
}

/// Serializes endpoint transitions and lease validation across observation tasks.
///
/// All mutable state is protected by `lock`, which is why this reference type can safely opt out of
/// compiler-derived `Sendable` checking.
final class DesktopLeaseAuthority: @unchecked Sendable {
    static let shared = DesktopLeaseAuthority()

    private let lock = NSLock()
    private var lifecycle: DesktopEndpointLifecycle = .unavailable(endpointEpoch: 0)
    private var generations: [ResumeKey: UInt64] = [:]

    /// Canonicalizes the latest settings address and advances the epoch only for identity changes.
    ///
    /// Desktop observation pipelines call this for every persisted address emission. Advancing the
    /// epoch also invalidates every message-connection generation.
    func transition(to rawAddress: String?) -> DesktopEndpointLifecycle {
        lock.withLock {
            let nextIdentity = rawAddress.flatMap {
                DesktopEndpoint(rawAddress: $0)
            }
            let hasSameIdentity: Bool
            switch (lifecycle, nextIdentity) {
            case (.unavailable, nil):
                hasSameIdentity = true
            case let (.configured(current, _), next?):
                hasSameIdentity = current == next
            default:
                hasSameIdentity = false
            }
            guard !hasSameIdentity else {
                return lifecycle
            }

            let epoch = lifecycle.endpointEpoch &+ 1
            generations.removeAll()
            if let endpoint = nextIdentity {
                lifecycle = .configured(endpoint: endpoint, endpointEpoch: epoch)
            } else {
                lifecycle = .unavailable(endpointEpoch: epoch)
            }
            return lifecycle
        }
    }

    /// Creates the newest connection generation if the caller's endpoint epoch is still current.
    func beginConnection(resumeKey: ResumeKey, endpointEpoch: UInt64) -> ConnectionLease? {
        lock.withLock {
            guard case let .configured(_, currentEpoch) = lifecycle,
                  currentEpoch == endpointEpoch else {
                return nil
            }
            let generation = generations[resumeKey, default: 0] &+ 1
            generations[resumeKey] = generation
            return ConnectionLease(
                resumeKey: resumeKey,
                generation: generation,
                endpointEpoch: endpointEpoch
            )
        }
    }

    /// Runs one synchronous transcript transaction only while its socket lease is current.
    ///
    /// The lock remains held through `operation`, so an endpoint transition cannot interleave with
    /// the database mutation and let an obsolete socket commit after an address change.
    func withValidLease<Value>(
        _ lease: ConnectionLease,
        operation: () throws -> Value
    ) throws -> Value? {
        try lock.withLock {
            guard case let .configured(_, currentEpoch) = lifecycle,
                  currentEpoch == lease.endpointEpoch,
                  generations[lease.resumeKey] == lease.generation else {
                return nil
            }
            return try operation()
        }
    }

    /// Runs one synchronous HTTP-workflow transaction only while its endpoint lease is current.
    func withValidRequestLease<Value>(
        _ lease: DesktopRequestLease,
        operation: () throws -> Value
    ) rethrows -> Value? {
        try lock.withLock {
            guard case let .configured(_, currentEpoch) = lifecycle,
                  currentEpoch == lease.endpointEpoch else {
                return nil
            }
            return try operation()
        }
    }

    /// Checks whether a delayed response may still be published to feature state.
    func isValid(_ lease: DesktopRequestLease) -> Bool {
        lock.withLock {
            guard case let .configured(_, currentEpoch) = lifecycle else {
                return false
            }
            return currentEpoch == lease.endpointEpoch
        }
    }
}

private extension String {
    /// Removes a known URL scheme prefix while preserving an optional failure for canonicalization.
    func dropPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else {
            return nil
        }
        return String(dropFirst(prefix.count))
    }
}
