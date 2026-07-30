//
//  DesktopClient.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Dependencies
import DependenciesMacros
import Foundation
import SharedConductorData
import Sharing

private let liveModelSettingsCache = DesktopClient.ModelSettingsCache()

@DependencyClient
public struct DesktopClient: Sendable {
    public typealias MessageDeliveryResult = SharedConductorData.MessageDeliveryResult
    public typealias MessageMode = SharedConductorData.MessageSendMode

    public var archiveWorkspace: @Sendable (_ workspaceID: String) async throws -> Void
    /// Captures the current endpoint identity for a multi-step request/persistence workflow.
    public var acquireRequestLease: @Sendable () throws -> DesktopRequestLease
    public var beginQueuedMessageEdit: @Sendable (_ workspaceID: String, _ sessionID: String, _ messageID: Message.ID) async throws -> QueuedMessageEdit
    public var checkConnection: @Sendable (_ serverAddress: String) async throws -> Void
    public var closeSession: @Sendable (_ workspaceID: String, _ sessionID: String) async throws -> Void
    public var createSession: @Sendable (_ workspaceID: String) async throws -> Session
    public var createWorkspace: @Sendable (
        _ workspaceID: Workspace.ID,
        _ repositoryID: Repository.ID,
        _ agentType: Session.AgentType,
        _ model: Session.Model,
        _ isFastModeEnabled: Bool
    ) async throws -> CreatedWorkspace
    /// Returns the settings already fetched for the currently configured desktop this launch.
    public var cachedModelSettings: @Sendable () -> ModelSettings? = {
        nil
    }
    public var deleteQueuedMessage: @Sendable (_ workspaceID: String, _ sessionID: String, _ messageID: Message.ID) async throws -> Void
    public var fetchModelSettings: @Sendable () async throws -> ModelSettings = {
        throw CancellationError()
    }
    public var fetchSessionModelHistory: @Sendable (
        _ workspaceID: Workspace.ID,
        _ sessionID: Session.ID
    ) async throws -> Session.ModelHistory
    /// Rejects delayed feature actions after the configured desktop endpoint changes.
    ///
    /// The dependency macro requires a non-throwing default. `false` fails closed so a test that
    /// forgets to provide epoch behavior cannot accidentally accept stale endpoint data.
    public var isRequestLeaseValid: @Sendable (_ lease: DesktopRequestLease) -> Bool = { _ in
        false
    }
    /// Persists a created session only while its originating desktop endpoint remains current.
    public var persistCreatedSession: @Sendable (
        _ session: Session,
        _ requestLease: DesktopRequestLease
    ) async throws -> Void
    /// Persists a created workspace/session pair only while its originating endpoint remains current.
    public var persistCreatedWorkspace: @Sendable (
        _ createdWorkspace: CreatedWorkspace,
        _ requestLease: DesktopRequestLease
    ) async throws -> Void
    public var observeMessages: @Sendable (_ workspaceID: String, _ sessionID: String) -> AsyncThrowingStream<DesktopMessageObservation, any Error> = { _, _ in
        AsyncThrowingStream { $0.finish() }
    }
    public var observeMessageEvents: @Sendable (_ workspaceID: String, _ sessionID: String) -> AsyncThrowingStream<MessageSyncEvent, any Error> = { _, _ in
        AsyncThrowingStream { $0.finish() }
    }
    public var observeSessions: @Sendable (_ workspaceID: String) -> AsyncThrowingStream<[Session], any Error> = { _ in
        AsyncThrowingStream { $0.finish() }
    }
    public var observeWorkspaces: @Sendable () -> AsyncThrowingStream<WorkspaceListSnapshot, any Error> = {
        AsyncThrowingStream { $0.finish() }
    }
    public var ping: @Sendable () async throws -> Void = { }
    public var renameWorkspaceBranch: @Sendable (
        _ workspaceID: String,
        _ branch: String
    ) async throws -> Void
    public var renameSession: @Sendable (_ workspaceID: String, _ sessionID: String, _ title: String) async throws -> Void
    public var restoreSession: @Sendable (_ workspaceID: String, _ sessionID: String) async throws -> Void
    public var finishQueuedMessageEdit: @Sendable (
        _ workspaceID: String,
        _ sessionID: String,
        _ messageID: Message.ID,
        _ content: String,
        _ shouldResumeQueue: Bool
    ) async throws -> Void
    public var reorderQueuedMessages: @Sendable (_ workspaceID: String, _ sessionID: String, _ messageIDs: [Message.ID]) async throws -> Void
    public var resumeQueuedMessages: @Sendable (_ workspaceID: String, _ sessionID: String) async throws -> Void
    public var sendMessage: @Sendable (
        _ workspaceID: String,
        _ sessionID: String,
        _ message: String,
        _ model: Session.Model,
        _ isFastModeEnabled: Bool,
        _ mode: MessageMode,
        _ reasoningEffort: Session.ReasoningEffort?,
        _ attemptID: UUID
    ) async throws -> MessageDeliveryResult = { _, _, _, _, _, _, _, _ in
        .unknown(reason: "Delivery could not be determined.")
    }
    public var setWorkspacePinned: @Sendable (_ workspaceID: String, _ isPinned: Bool) async throws -> UIHookMutationPath
    public var setWorkspaceStatus: @Sendable (_ workspaceID: String, _ status: Workspace.Status) async throws -> UIHookMutationPath
    public var setWorkspaceUnread: @Sendable (_ workspaceID: String, _ isUnread: Bool) async throws -> UIHookMutationPath
    public var stopSession: @Sendable (_ workspaceID: String, _ sessionID: String) async throws -> Session?
    public var steerQueuedMessage: @Sendable (_ workspaceID: String, _ sessionID: String, _ messageID: Message.ID) async throws -> Void

    public enum ConnectionStatus: Equatable, Sendable {
        case connected
        case connecting
        case disconnected
    }

    public enum DeviceIcon: String, CaseIterable, Codable, Equatable, Sendable {
        case desktop
        case laptop
        case server
    }

    public struct DisplayConfiguration: Codable, Equatable, Sendable {
        public var name: String
        public var icon: DeviceIcon

        public init(name: String, icon: DeviceIcon) {
            self.name = name
            self.icon = icon
        }
    }

    public struct ModelSettings: Codable, Equatable, Sendable {
        public static let conductorDefaults = Self(
            defaultModel: .opus5_1M,
            defaultReasoningEffort: .high,
            isFastModeEnabled: false
        )

        public var defaultModel: Session.Model
        public var defaultReasoningEffort: Session.ReasoningEffort
        public var isFastModeEnabled: Bool

        public init(
            defaultModel: Session.Model,
            defaultReasoningEffort: Session.ReasoningEffort,
            isFastModeEnabled: Bool
        ) {
            self.defaultModel = defaultModel
            self.defaultReasoningEffort = defaultReasoningEffort
            self.isFastModeEnabled = isFastModeEnabled
        }
    }

    fileprivate final class ModelSettingsCache: @unchecked Sendable {
        private struct CachedValue {
            let settings: ModelSettings
            let url: URL
        }

        private struct Request {
            let id: UUID
            let task: Task<ModelSettings, any Error>
            let url: URL
        }

        private enum Lookup {
            case cached(ModelSettings)
            case request(Request)
        }

        private let lock = NSLock()
        private var cachedValue: CachedValue?
        private var request: Request?

        func cachedValue(for url: URL) -> ModelSettings? {
            lock.withLock {
                guard cachedValue?.url == url else {
                    return nil
                }
                return cachedValue?.settings
            }
        }

        func value(
            for url: URL,
            load: @escaping @Sendable () async throws -> ModelSettings
        ) async throws -> ModelSettings {
            let lookup = lock.withLock {
                if let cachedValue, cachedValue.url == url {
                    return Lookup.cached(cachedValue.settings)
                }
                if let request, request.url == url {
                    return Lookup.request(request)
                }
                let request = Request(
                    id: UUID(),
                    task: Task {
                        try await load()
                    },
                    url: url
                )
                self.request = request
                return Lookup.request(request)
            }

            switch lookup {
            case let .cached(settings):
                return settings

            case let .request(request):
                do {
                    let settings = try await request.task.value
                    lock.withLock {
                        guard self.request?.id == request.id else {
                            return
                        }
                        cachedValue = CachedValue(settings: settings, url: url)
                        self.request = nil
                    }
                    return settings
                } catch {
                    lock.withLock {
                        guard self.request?.id == request.id else {
                            return
                        }
                        self.request = nil
                    }
                    throw error
                }
            }
        }
    }

    public struct QueuedMessageEdit: Codable, Equatable, Sendable {
        public let message: Message
        public let shouldResumeQueue: Bool

        public init(message: Message, shouldResumeQueue: Bool) {
            self.message = message
            self.shouldResumeQueue = shouldResumeQueue
        }

        private enum CodingKeys: String, CodingKey {
            case message
            case shouldResumeQueue = "should_resume_queue"
        }
    }
}

public extension SharedKey where Self == InMemoryKey<DesktopClient.ConnectionStatus>.Default {
    static var desktopConnectionStatus: Self {
        Self[
            .inMemory("desktopConnectionStatus"),
            default: .connecting,
        ]
    }
}

// Specifies how the change was persisted on a successful POST/PATCH call
public enum UIHookMutationPath: Equatable, Sendable {
    /// Change was propagated through the UI hook
    ///
    /// 204
    case hook

    /// Used sqlite so the Conductor window is likely stale.
    /// We generally show an alert when this happens
    ///
    /// Code 202
    case sqliteFallback
}

public enum DesktopClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidResponse
    case invalidServerAddress
    case requestFailed(statusCode: Int, message: String)
    case staleRequestLease

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The desktop service returned an invalid response."

        case .invalidServerAddress:
            "Enter a valid desktop server address."

        case let .requestFailed(statusCode, message):
            if message.isEmpty {
                "The desktop service returned HTTP \(statusCode)."
            } else {
                "The desktop service returned HTTP \(statusCode): \(message)"
            }

        case .staleRequestLease:
            "The desktop configuration changed before the request completed."
        }
    }

    public static func isConnectionFailure(_ error: any Error) -> Bool {
        let nsError = error as NSError
        // iOS can abort a WebSocket while the app is suspended. Treat that like other transient
        // transport loss so observations reconnect instead of presenting an alert.
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(POSIXErrorCode.ECANCELED.rawValue)
                || nsError.code == Int(POSIXErrorCode.ECONNABORTED.rawValue)
                || nsError.code == Int(POSIXErrorCode.ENOTCONN.rawValue) {
            return true
        }

        guard let urlError = error as? URLError else {
            return false
        }

        return switch urlError.code {
        case .cannotConnectToHost,
             .cannotFindHost,
             .dataNotAllowed,
             .dnsLookupFailed,
             .internationalRoamingOff,
             .networkConnectionLost,
             .notConnectedToInternet,
             .timedOut:
            true

        default:
            false
        }
    }
}

extension DesktopClient: DependencyKey {
    static let defaultServerPort = 3_768

    public static var liveValue: Self {
        Self { workspaceID in
            _ = try await patch(
                WorkspacePatchBody(shouldArchive: true),
                at: workspaceURL(workspaceID: workspaceID)
            )
        } acquireRequestLease: {
            // Capture the canonical endpoint and epoch together. Feature workflows carry this
            // lease through every request and synchronous persistence boundary.
            @Shared(.desktopServerAddress) var desktopServerAddress
            let lifecycle = DesktopLeaseAuthority.shared.transition(to: desktopServerAddress)
            guard case let .configured(endpoint, endpointEpoch) = lifecycle,
                  let baseURL = endpoint.url(scheme: "http") else {
                throw DesktopClientError.invalidServerAddress
            }
            return DesktopRequestLease(
                baseURL: baseURL,
                endpointEpoch: endpointEpoch
            )
        } beginQueuedMessageEdit: { workspaceID, sessionID, messageID in
            guard let edit = try await post(
                [String: String](),
                to: try queueURL(workspaceID: workspaceID, sessionID: sessionID)
                    .appending(path: messageID)
                    .appending(path: "edit"),
                decoding: QueuedMessageEdit.self
            ) else {
                throw DesktopClientError.invalidResponse
            }
            return edit
        } checkConnection: { serverAddress in
            try await ping(serverAddress: serverAddress)
        } closeSession: { workspaceID, sessionID in
            _ = try await patch(
                SessionPatchBody(isHidden: true),
                at: sessionURL(workspaceID: workspaceID, sessionID: sessionID)
            )
        } createSession: { workspaceID in
            guard let session = try await post(
                [String: String](),
                to: sessionsURL(workspaceID: workspaceID),
                decoding: Session.self
            ) else {
                throw DesktopClientError.invalidResponse
            }
            return session
        } createWorkspace: {
            workspaceID,
            repositoryID,
            agentType,
            model,
            isFastModeEnabled in
            guard let createdWorkspace = try await post(
                CreateWorkspaceBody(
                    workspaceID: workspaceID,
                    repositoryID: repositoryID,
                    agentType: agentType.rawValue,
                    model: model.rawValue,
                    isFastModeEnabled: isFastModeEnabled
                ),
                to: baseURL().appending(path: "workspaces"),
                decoding: CreatedWorkspace.self,
                // Leave transport headroom beyond the server's five-minute creation window.
                timeoutInterval: 330
            ) else {
                throw DesktopClientError.invalidResponse
            }
            return createdWorkspace
        } cachedModelSettings: {
            guard let url = try? settingsURL() else {
                return nil
            }
            return liveModelSettingsCache.cachedValue(for: url)
        } deleteQueuedMessage: { workspaceID, sessionID, messageID in
            let request = try jsonRequest(
                method: "DELETE",
                body: [String: String](),
                url: try queueURL(workspaceID: workspaceID, sessionID: sessionID)
                    .appending(path: messageID)
            )
            let (data, response) = try await data(for: request)
            try validateSuccessfulHTTPResponse(response, data: data)
        } fetchModelSettings: {
            let url = try settingsURL()
            return try await liveModelSettingsCache.value(for: url) {
                let settings = try await get(SettingsResponse.self, from: url)
                let defaultModel = Session.Model(rawValue: settings.defaultModel)
                return ModelSettings(
                    defaultModel: defaultModel,
                    defaultReasoningEffort: settings.defaultReasoningEffort.map {
                        Session.ReasoningEffort(rawValue: $0)
                    } ?? defaultModel.defaultReasoningEffort,
                    isFastModeEnabled: settings.defaultFastMode ?? false
                )
            }
        } fetchSessionModelHistory: { workspaceID, sessionID in
            try await get(
                Session.ModelHistory.self,
                from: sessionURL(
                    workspaceID: workspaceID,
                    sessionID: sessionID
                )
                .appending(path: "model-history"),
                timeoutInterval: 3
            )
        } isRequestLeaseValid: { lease in
            @Shared(.desktopServerAddress) var desktopServerAddress
            return DesktopLeaseAuthority.shared.isValid(
                lease,
                serverAddress: desktopServerAddress
            )
        } persistCreatedSession: { session, requestLease in
            @Dependency(\.defaultDatabase) var database
            try await database.write { database in
                @Shared(.desktopServerAddress) var desktopServerAddress
                let persistenceResult: Void? = try requestLease.performIfCurrent(
                    serverAddress: desktopServerAddress
                ) {
                    try Session.upsert { session }.execute(database)
                }
                guard persistenceResult != nil else {
                    throw DesktopClientError.staleRequestLease
                }
            }
        } persistCreatedWorkspace: { createdWorkspace, requestLease in
            @Dependency(\.defaultDatabase) var database
            try await database.write { database in
                @Shared(.desktopServerAddress) var desktopServerAddress
                let persistenceResult: Void? = try requestLease.performIfCurrent(
                    serverAddress: desktopServerAddress
                ) {
                    try Workspace.upsert {
                        createdWorkspace.workspace
                    }
                    .execute(database)
                    try Session.upsert {
                        createdWorkspace.session
                    }
                    .execute(database)
                }
                guard persistenceResult != nil else {
                    throw DesktopClientError.staleRequestLease
                }
            }
        } observeMessages: { workspaceID, sessionID in
            observeMessages(workspaceID: workspaceID, sessionID: sessionID)
        } observeMessageEvents: { workspaceID, sessionID in
            observeMessageEvents(
                workspaceID: workspaceID,
                sessionID: sessionID
            )
        } observeSessions: { workspaceID in
            observe([Session].self) { serverAddress in
                sessionsWebSocketURL(
                    serverAddress: serverAddress,
                    workspaceID: workspaceID
                )
            }
        } observeWorkspaces: {
            observe(WorkspaceListSnapshot.self) { serverAddress in
                workspacesWebSocketURL(serverAddress: serverAddress)
            }
        } ping: {
            try await ping()
        } renameWorkspaceBranch: { workspaceID, branch in
            _ = try await patch(
                WorkspacePatchBody(branch: branch),
                at: workspaceURL(workspaceID: workspaceID)
            )
        } renameSession: { workspaceID, sessionID, title in
            _ = try await patch(
                SessionPatchBody(title: title),
                at: sessionURL(workspaceID: workspaceID, sessionID: sessionID)
            )
        } restoreSession: { workspaceID, sessionID in
            _ = try await patch(
                SessionPatchBody(isHidden: false),
                at: sessionURL(workspaceID: workspaceID, sessionID: sessionID)
            )
        } finishQueuedMessageEdit: {
            workspaceID,
            sessionID,
            messageID,
            content,
            shouldResumeQueue in
            let request = try jsonRequest(
                method: "PATCH",
                body: QueuedMessageEditBody(
                    content: content,
                    shouldResumeQueue: shouldResumeQueue
                ),
                url: queueURL(workspaceID: workspaceID, sessionID: sessionID)
                    .appending(path: messageID)
            )
            let (data, response) = try await data(for: request)
            try validateSuccessfulHTTPResponse(response, data: data)
        } reorderQueuedMessages: { workspaceID, sessionID, messageIDs in
            let request = try jsonRequest(
                method: "PATCH",
                body: QueueOrderBody(messageIDs: messageIDs),
                url: queueURL(workspaceID: workspaceID, sessionID: sessionID)
            )
            let (data, response) = try await data(for: request)
            try validateSuccessfulHTTPResponse(response, data: data)
        } resumeQueuedMessages: { workspaceID, sessionID in
            let request = try jsonRequest(
                method: "POST",
                body: [String: String](),
                url: queueURL(workspaceID: workspaceID, sessionID: sessionID)
                    .appending(path: "resume")
            )
            let (data, response) = try await data(for: request)
            try validateSuccessfulHTTPResponse(response, data: data)
        } sendMessage: {
            workspaceID,
            sessionID,
            message,
            model,
            isFastModeEnabled,
            mode,
            reasoningEffort,
            attemptID in
            try await sendMessage(
                workspaceID: workspaceID,
                sessionID: sessionID,
                message: message,
                model: model,
                isFastModeEnabled: isFastModeEnabled,
                mode: mode,
                reasoningEffort: reasoningEffort,
                attemptID: attemptID
            )
        } setWorkspacePinned: { workspaceID, isPinned in
            try await patch(
                WorkspacePatchBody(isPinned: isPinned),
                at: workspaceURL(workspaceID: workspaceID)
            )
        } setWorkspaceStatus: { workspaceID, status in
            try await patch(
                WorkspacePatchBody(status: status.rawValue),
                at: workspaceURL(workspaceID: workspaceID)
            )
        } setWorkspaceUnread: { workspaceID, isUnread in
            try await patch(
                WorkspacePatchBody(isUnread: isUnread),
                at: workspaceURL(workspaceID: workspaceID)
            )
        } stopSession: { workspaceID, sessionID in
            try await post(
                [String: String](),
                // POST /workspaces/{workspaceID}/sessions/{sessionID}/stop
                to: sessionURL(workspaceID: workspaceID, sessionID: sessionID)
                    .appending(path: "stop"),
                decoding: Session.self
            )
        } steerQueuedMessage: { workspaceID, sessionID, messageID in
            let request = try jsonRequest(
                method: "POST",
                body: [String: String](),
                url: try queueURL(workspaceID: workspaceID, sessionID: sessionID)
                    .appending(path: messageID)
                    .appending(path: "steer")
            )
            let (data, response) = try await data(for: request)
            try validateSuccessfulHTTPResponse(response, data: data)
        }
    }

    private static func baseURL() throws -> URL {
        @Shared(.desktopServerAddress) var desktopServerAddress
        // A task-local lease pins multi-request workflows to their starting endpoint. Checking it
        // before each request prevents a later step from silently switching to a new desktop.
        if let lease = DesktopRequestLeaseContext.current {
            guard DesktopLeaseAuthority.shared.isValid(
                lease,
                serverAddress: desktopServerAddress
            ) else {
                throw DesktopClientError.staleRequestLease
            }
            return lease.baseURL
        }
        guard let desktopServerAddress,
              let baseURL = serverURL(scheme: "http", address: desktopServerAddress)
        else {
            throw DesktopClientError.invalidServerAddress
        }
        return baseURL
    }

    /// Builds a base URL from the settings address after canonical endpoint validation.
    static func serverURL(scheme: String, address: String) -> URL? {
        DesktopEndpoint(rawAddress: address)?.url(scheme: scheme)
    }

    static func ping(serverAddress: String) async throws {
        guard let url = serverURL(scheme: "http", address: serverAddress)?
            .appending(path: "ping")
        else {
            throw DesktopClientError.invalidServerAddress
        }

        // Settings can probe an unsaved draft address without changing the live connection status.
        @Dependency(\.urlSession) var urlSession

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let session = URLSession(
            configuration: localNetworkConfiguration(
                from: urlSession.configuration
            )
        )
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        try validateSuccessfulHTTPResponse(response, data: data)
    }

    private static func ping() async throws {
        @Shared(.desktopConnectionStatus) var connectionStatus
        @Shared(.desktopServerAddress) var desktopServerAddress
        guard let desktopServerAddress else {
            return
        }

        $connectionStatus.withLock {
            if $0 == .disconnected {
                $0 = .connecting
            }
        }

        guard let url = serverURL(scheme: "http", address: desktopServerAddress)?
            .appending(path: "ping")
        else {
            throw DesktopClientError.invalidServerAddress
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let (data, response) = try await data(for: request)
        try validateSuccessfulHTTPResponse(response, data: data)
    }

    private struct SettingsResponse: Decodable {
        let defaultModel: String
        let defaultFastMode: Bool?
        let defaultReasoningEffort: String?
    }

    private static func settingsURL() throws -> URL {
        try baseURL().appending(path: "settings")
    }

    // POST /workspaces/{workspaceID}/sessions/{sessionID}/messages
    private static func messagesURL(workspaceID: String, sessionID: String) throws -> URL {
        try sessionURL(workspaceID: workspaceID, sessionID: sessionID)
            .appending(path: "messages")
    }

    private static func queueURL(workspaceID: String, sessionID: String) throws -> URL {
        try messagesURL(workspaceID: workspaceID, sessionID: sessionID)
            .appending(path: "queue")
    }

    private static func sendMessage(
        workspaceID: String,
        sessionID: String,
        message: String,
        model: Session.Model,
        isFastModeEnabled: Bool,
        mode: MessageMode,
        reasoningEffort: Session.ReasoningEffort?,
        attemptID: UUID
    ) async throws -> MessageDeliveryResult {
        let request: URLRequest
        do {
            request = try jsonRequest(
                method: "POST",
                body: MessageSendRequest(
                    attemptID: attemptID,
                    isFastModeEnabled: isFastModeEnabled,
                    message: message,
                    model: model.rawValue,
                    mode: mode,
                    reasoningEffort: reasoningEffort
                ),
                url: messagesURL(workspaceID: workspaceID, sessionID: sessionID),
                timeoutInterval: 10
            )
        } catch {
            return .rejected(
                reason: "The message request could not be created: \(error.localizedDescription)"
            )
        }

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return .unknown(reason: "Delivery could not be determined.")
        }

        guard let response = response as? HTTPURLResponse else {
            return .unknown(reason: "Delivery could not be determined.")
        }
        guard response.statusCode == 200 else {
            if response.statusCode == 400 {
                let reason = errorMessage(from: responseData)
                return .rejected(
                    reason: reason.isEmpty ? "Message was rejected." : reason
                )
            }
            return .unknown(reason: "Delivery could not be determined.")
        }
        guard let response = try? JSONDecoder.conductor.decode(
            MessageSendResponse.self,
            from: responseData
        ), response.attemptID == attemptID else {
            return .unknown(reason: "Delivery could not be determined.")
        }

        return response.result
    }

    // /workspaces/{workspaceID}/sessions/{sessionID}
    private static func sessionURL(workspaceID: String, sessionID: String) throws -> URL {
        try sessionsURL(workspaceID: workspaceID)
            .appending(path: sessionID)
    }

    // POST /workspaces/{workspaceID}/sessions
    private static func sessionsURL(workspaceID: String) throws -> URL {
        try workspaceURL(workspaceID: workspaceID)
            .appending(path: "sessions")
    }

    private static func workspaceURL(workspaceID: String) throws -> URL {
        try baseURL()
            .appending(path: "workspaces")
            .appending(path: workspaceID)
    }

    private static func post<Body: Encodable, Response: Decodable>(
        _ body: Body,
        to url: URL,
        decoding responseType: Response.Type,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> Response? {
        var request = try jsonRequest(method: "POST", body: body, url: url)
        if let timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }
        let (data, response) = try await data(for: request)
        let statusCode = try validateSuccessfulHTTPResponse(response, data: data)
        guard statusCode != 204 else {
            return nil
        }
        return try JSONDecoder.conductor.decode(responseType, from: data)
    }

    private static func get<Response: Decodable>(
        _ responseType: Response.Type,
        from url: URL,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> Response {
        var request = URLRequest(url: url)
        if let timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }
        let (data, response) = try await data(for: request)
        try validateSuccessfulHTTPResponse(response, data: data)
        return try JSONDecoder.conductor.decode(responseType, from: data)
    }

    // URLSession only throws for transport failures, so validate HTTP status codes separately.
    @discardableResult
    private static func validateSuccessfulHTTPResponse(
        _ response: URLResponse,
        data: Data
    ) throws -> Int {
        guard let response = response as? HTTPURLResponse else {
            throw DesktopClientError.invalidResponse
        }

        guard (200..<300).contains(response.statusCode) else {
            throw DesktopClientError.requestFailed(
                statusCode: response.statusCode,
                message: errorMessage(from: data)
            )
        }
        return response.statusCode
    }

    static func errorMessage(from data: Data) -> String {
        (try? JSONDecoder().decode(ErrorResponse.self, from: data).error.message)
            ?? String(decoding: data, as: UTF8.self)
    }

    private struct ErrorResponse: Decodable {
        let error: Details

        struct Details: Decodable {
            let message: String
        }
    }

    private static func patch<Body: Encodable & Sendable>(
        _ body: Body,
        at url: URL
    ) async throws -> UIHookMutationPath {
        let request = try jsonRequest(method: "PATCH", body: body, url: url)
        let (data, response) = try await data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw DesktopClientError.invalidResponse
        }

        return try getUIHookMutationPathFromStatusCode(
            statusCode: response.statusCode,
            data: data
        )
    }

    private static func jsonRequest<Body: Encodable>(
        method: String,
        body: Body,
        url: URL,
        timeoutInterval: TimeInterval? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        if let timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }
        request.httpMethod = method
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    static func getUIHookMutationPathFromStatusCode(
        statusCode: Int,
        data: Data = Data()
    ) throws -> UIHookMutationPath {
        switch statusCode {
        case 204:
            return .hook

        case 202:
            return .sqliteFallback

        default:
            throw DesktopClientError.requestFailed(
                statusCode: statusCode,
                message: String(decoding: data, as: UTF8.self)
            )
        }
    }

    private static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        @Dependency(\.urlSession) var urlSession
        @Shared(.desktopConnectionStatus) var connectionStatus
        let session = URLSession(
            configuration: localNetworkConfiguration(
                from: urlSession.configuration
            )
        )
        defer { session.invalidateAndCancel() }

        do {
            let result = try await session.data(for: request)
            $connectionStatus.withLock { $0 = .connected }
            return result
        } catch {
            if DesktopClientError.isConnectionFailure(error) {
                $connectionStatus.withLock { $0 = .disconnected }
            }
            throw error
        }
    }

    static func localNetworkConfiguration(
        from configuration: URLSessionConfiguration
    ) -> URLSessionConfiguration {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.connectionProxyDictionary = [:]
        return configuration
    }
}

private struct CreateWorkspaceBody: Encodable, Sendable {
    let workspaceID: Workspace.ID
    let repositoryID: Repository.ID
    let agentType: String
    let model: String
    let isFastModeEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case repositoryID = "repository_id"
        case agentType = "agent_type"
        case model
        case isFastModeEnabled = "fast_mode"
    }
}

struct WorkspacePatchBody: Encodable, Sendable {
    var shouldArchive: Bool? = nil
    var branch: String? = nil
    var isPinned: Bool? = nil
    var status: String? = nil
    var isUnread: Bool? = nil

    private enum CodingKeys: String, CodingKey {
        case shouldArchive = "archive"
        case branch
        case isPinned = "pinned"
        case isUnread = "unread"
        case status
    }
}

private struct SessionPatchBody: Encodable, Sendable {
    var isHidden: Bool? = nil
    var title: String? = nil

    private enum CodingKeys: String, CodingKey {
        case isHidden = "hidden"
        case title
    }
}

struct QueueOrderBody: Encodable, Sendable {
    let messageIDs: [Message.ID]

    private enum CodingKeys: String, CodingKey {
        case messageIDs = "message_ids"
    }
}

struct QueuedMessageEditBody: Encodable, Sendable {
    let content: String
    let shouldResumeQueue: Bool

    private enum CodingKeys: String, CodingKey {
        case content
        case shouldResumeQueue = "resume_queue"
    }
}

public extension DesktopClient {
    // GET /repositories/{repositoryID}/icon
    static func repositoryIconURL(for repository: Repository) -> URL? {
        try? baseURL()
            .appending(path: "repositories")
            .appending(path: repository.id)
            .appending(path: "icon")
    }
}

public extension DependencyValues {
    var desktopClient: DesktopClient {
        get { self[DesktopClient.self] }
        set { self[DesktopClient.self] = newValue }
    }
}

public extension SharedKey where Self == FileStorageKey<String?>.Default {
    static var desktopServerAddress: Self {
        Self[
            .fileStorage(
                .applicationSupportDirectory
                    .appending(component: "desktop-server-address.json")
            ),
            default: nil,
        ]
    }
}

public extension SharedKey
where Self == FileStorageKey<DesktopClient.DisplayConfiguration?>.Default {
    static var desktopDisplayConfiguration: Self {
        Self[
            .fileStorage(
                .applicationSupportDirectory
                    .appending(component: "desktop-display-configuration.json")
            ),
            default: nil,
        ]
    }
}

public extension SharedKey
where Self == FileStorageKey<DesktopClient.ModelSettings?>.Default {
    static var mobileModelSettingsOverride: Self {
        Self[
            .fileStorage(
                .applicationSupportDirectory
                    .appending(component: "mobile-model-settings-override.json")
            ),
            default: nil,
        ]
    }
}
