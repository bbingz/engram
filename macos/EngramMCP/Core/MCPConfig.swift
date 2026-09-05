import Darwin
import Foundation

struct MCPConfig {
    let dbPath: String
    let serviceSocketPath: String

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> MCPConfig {
        // HTTP daemon was removed from the product path; the MCP helper talks to
        // EngramService over a Unix socket only. The old daemonBaseURL /
        // bearerToken fields (and their force-unwrapped URL(string:)!) are gone.
        let defaultDBPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".engram/index.sqlite")
            .path
        let rawDBPath = environment["ENGRAM_MCP_DB_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dbPath: String
        if let rawDBPath, !rawDBPath.isEmpty {
            guard let normalized = UnixSocketEngramServiceTransport.normalizedAbsolutePath(rawDBPath) else {
                throw EngramServiceError.invalidRequest(
                    message: "ENGRAM_MCP_DB_PATH requires a non-empty absolute path"
                )
            }
            dbPath = normalized
        } else {
            dbPath = defaultDBPath
        }
        let serviceSocketPath = try UnixSocketEngramServiceTransport.resolvedSocketPath(
            environment: environment
        )
        return MCPConfig(
            dbPath: dbPath,
            serviceSocketPath: serviceSocketPath
        )
    }

    var isServiceSocketAvailable: Bool {
        var info = stat()
        guard lstat(serviceSocketPath, &info) == 0 else {
            return false
        }
        return (info.st_mode & S_IFMT) == S_IFSOCK
    }

    func canReachEngramService(timeout: TimeInterval = 1) async -> Bool {
        guard isServiceSocketAvailable else {
            return false
        }
        let transport = UnixSocketEngramServiceTransport(
            socketPath: serviceSocketPath,
            connectTimeout: timeout
        )
        let client = EngramServiceClient(
            transport: transport,
            defaultTimeout: timeout
        )
        defer { client.close() }
        do {
            _ = try await client.status()
            return true
        } catch {
            return false
        }
    }
}
