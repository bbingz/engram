import Darwin
import Foundation

struct MCPConfig {
    let dbPath: String
    let daemonBaseURL: URL
    let bearerToken: String?
    let serviceSocketPath: String

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> MCPConfig {
        let settings = readSettings()
        let dbPath = environment["ENGRAM_MCP_DB_PATH"]
            ?? expandHome("~/.engram/index.sqlite")
        let daemonBaseURL = URL(string: environment["ENGRAM_MCP_DAEMON_BASE_URL"]
            ?? defaultDaemonBaseURL(from: settings))!
        let bearerToken = environment["ENGRAM_MCP_BEARER_TOKEN"]
            ?? (settings["httpBearerToken"] as? String)
        let serviceSocketPath = environment["ENGRAM_MCP_SERVICE_SOCKET"]
            ?? environment["ENGRAM_SERVICE_SOCKET"]
            ?? defaultServiceSocketPath(environment: environment)
        return MCPConfig(
            dbPath: dbPath,
            daemonBaseURL: daemonBaseURL,
            bearerToken: bearerToken,
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

    private static func defaultDaemonBaseURL(from settings: [String: Any]) -> String {
        if let explicit = settings["httpBaseURL"] as? String, !explicit.isEmpty {
            return explicit
        }
        let port = settings["httpPort"] as? Int ?? 3457
        return "http://127.0.0.1:\(port)"
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

    private static func readSettings() -> [String: Any] {
        let path = expandHome("~/.engram/settings.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private static func expandHome(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(String(path.dropFirst(2)))
            .path
    }
}
