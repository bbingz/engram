import Darwin
import Foundation

struct MCPConfig {
    let dbPath: String
    let serviceSocketPath: String

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> MCPConfig {
        // HTTP daemon was removed from the product path; the MCP helper talks to
        // EngramService over a Unix socket only. The old daemonBaseURL /
        // bearerToken fields (and their force-unwrapped URL(string:)!) are gone.
        let dbPath = environment["ENGRAM_MCP_DB_PATH"]
            ?? expandHome("~/.engram/index.sqlite")
        let serviceSocketPath = environment["ENGRAM_MCP_SERVICE_SOCKET"]
            ?? environment["ENGRAM_SERVICE_SOCKET"]
            ?? defaultServiceSocketPath(environment: environment)
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
        defer {
            Task {
                await client.close()
            }
        }
        do {
            _ = try await client.status()
            return true
        } catch {
            return false
        }
    }

    private static func defaultServiceSocketPath(environment: [String: String]) -> String {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".engram", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("engram-service.sock")
            .path
    }

    private static func expandHome(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(String(path.dropFirst(2)))
            .path
    }
}
