import Foundation

public enum EngramRemoteBackendError: Error, Equatable {
    /// Refused: bearer token + bundles must travel over TLS (or loopback for tests).
    case insecureURL(String)
    case notHTTPResponse
    case unexpectedStatus(Int)
}

/// `RemoteStorageBackend` that talks to the self-hosted `engram-remote` server
/// over HTTP(S). The bundle bytes are sent in the clear over the connection — so
/// the connection MUST be TLS (terminated at the server or a reverse proxy); the
/// initializer refuses a non-HTTPS base URL unless it points at loopback (tests /
/// behind a local proxy). At-rest encryption is the server's responsibility
/// (server-held key).
public struct EngramRemoteBackend: RemoteStorageBackend {
    private let baseURL: URL
    private let token: String
    private let timeout: TimeInterval

    public init(baseURL: URL, token: String, timeout: TimeInterval = 60) throws {
        if baseURL.scheme?.lowercased() != "https" {
            let host = baseURL.host ?? ""
            let isLoopback = ["127.0.0.1", "localhost", "::1"].contains(host)
            guard isLoopback else { throw EngramRemoteBackendError.insecureURL(baseURL.absoluteString) }
        }
        self.baseURL = baseURL
        self.token = token
        self.timeout = timeout
    }

    private func request(_ method: String, key: String) -> URLRequest {
        let url = baseURL
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("bundles", isDirectory: true)
            .appendingPathComponent(key, isDirectory: false)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func status(_ response: URLResponse) throws -> Int {
        guard let http = response as? HTTPURLResponse else { throw EngramRemoteBackendError.notHTTPResponse }
        return http.statusCode
    }

    public func head(key: String) async throws -> Bool {
        let (_, response) = try await URLSession.shared.data(for: request("HEAD", key: key))
        switch try Self.status(response) {
        case 200: return true
        case 404: return false
        case let code: throw EngramRemoteBackendError.unexpectedStatus(code)
        }
    }

    public func put(key: String, data: Data) async throws {
        var req = request("PUT", key: key)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: req, from: data)
        switch try Self.status(response) {
        case 200, 201, 204: return
        case let code: throw EngramRemoteBackendError.unexpectedStatus(code)
        }
    }

    public func get(key: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request("GET", key: key))
        switch try Self.status(response) {
        case 200: return data
        case 404: throw RemoteSyncError.bundleNotFound(key: key)
        case let code: throw EngramRemoteBackendError.unexpectedStatus(code)
        }
    }

    public func delete(key: String) async throws {
        let (_, response) = try await URLSession.shared.data(for: request("DELETE", key: key))
        switch try Self.status(response) {
        case 200, 204, 404: return
        case let code: throw EngramRemoteBackendError.unexpectedStatus(code)
        }
    }
}
