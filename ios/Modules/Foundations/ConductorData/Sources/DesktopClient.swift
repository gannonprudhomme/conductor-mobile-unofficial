import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
public struct DesktopClient: Sendable {
    public var fetchSessions: @Sendable (_ workspaceID: String) async throws -> [Session]
    public var fetchWorkspaces: @Sendable () async throws -> [Workspace]
}

public enum DesktopClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidResponse
    case requestFailed(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The desktop service returned an invalid response."

        case let .requestFailed(statusCode, message):
            if message.isEmpty {
                "The desktop service returned HTTP \(statusCode)."
            } else {
                "The desktop service returned HTTP \(statusCode): \(message)"
            }
        }
    }
}

extension DesktopClient: DependencyKey {
    public static var liveValue: Self {
        Self(
            fetchSessions: { workspaceID in
                try await fetch(
                    [Session].self,
                    from: baseURL
                        .appending(path: "workspaces")
                        .appending(path: workspaceID)
                        .appending(path: "sessions")
                )
            },
            fetchWorkspaces: {
                try await fetch(
                    [Workspace].self,
                    from: baseURL.appending(path: "workspaces")
                )
            }
        )
    }

    private static let baseURL = URL(string: "http://127.0.0.1:3768")!

    private static func fetch<Value: Decodable & Sendable>(
        _ type: Value.Type,
        from url: URL
    ) async throws -> Value {
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let response = response as? HTTPURLResponse
        else { throw DesktopClientError.invalidResponse }

        guard response.statusCode == 200
        else {
            throw DesktopClientError.requestFailed(
                statusCode: response.statusCode,
                message: String(decoding: data, as: UTF8.self)
            )
        }

        return try JSONDecoder().decode(type, from: data)
    }
}

public extension DependencyValues {
    var desktopClient: DesktopClient {
        get { self[DesktopClient.self] }
        set { self[DesktopClient.self] = newValue }
    }
}
