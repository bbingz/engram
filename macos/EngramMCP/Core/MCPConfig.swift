import Foundation

struct MCPConfig {
    let dbPath: String
    let daemonBaseURL: URL
    let bearerToken: String?

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> MCPConfig {
        let settings = readSettings()
        let dbPath = environment["ENGRAM_MCP_DB_PATH"]
            ?? expandHome("~/.engram/index.sqlite")
        let daemonBaseURL = URL(string: environment["ENGRAM_MCP_DAEMON_BASE_URL"]
            ?? defaultDaemonBaseURL(from: settings))!
        let bearerToken = environment["ENGRAM_MCP_BEARER_TOKEN"]
            ?? (settings["httpBearerToken"] as? String)
        return MCPConfig(
            dbPath: dbPath,
            daemonBaseURL: daemonBaseURL,
            bearerToken: bearerToken
        )
    }

    private static func defaultDaemonBaseURL(from settings: [String: Any]) -> String {
        if let explicit = settings["httpBaseURL"] as? String, !explicit.isEmpty {
            return explicit
        }
        let port = settings["httpPort"] as? Int ?? 3457
        return "http://127.0.0.1:\(port)"
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
