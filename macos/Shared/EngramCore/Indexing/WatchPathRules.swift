import Foundation

public struct WatchEntry: Equatable, Sendable {
    public var path: String
    public var source: SourceName

    public init(path: String, source: SourceName) {
        self.path = path
        self.source = source
    }
}

public struct WatchBatchConfig: Equatable, Sendable {
    public var writeStabilityMilliseconds: Int
    public var pollMilliseconds: Int
    public var maxDrainBatchSize: Int

    public init(writeStabilityMilliseconds: Int = 2_000, pollMilliseconds: Int = 500, maxDrainBatchSize: Int = 500) {
        self.writeStabilityMilliseconds = writeStabilityMilliseconds
        self.pollMilliseconds = pollMilliseconds
        self.maxDrainBatchSize = maxDrainBatchSize
    }

    public static func load(from url: URL) throws -> WatchBatchConfig {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return WatchBatchConfig(
            writeStabilityMilliseconds: object?["watchWriteStabilityMs"] as? Int ?? 2_000,
            pollMilliseconds: object?["watchWriteStabilityPollMs"] as? Int ?? 500,
            maxDrainBatchSize: object?["startupParentBackfillLimit"] as? Int ?? 500
        )
    }
}

public enum WatchPathRules {
    public static let watchedSources: Set<SourceName> = [
        .codex,
        .claudeCode,
        .geminiCli,
        .antigravity,
        .iflow,
        .qwen,
        .kimi,
        .pi,
        .cline,
        .lobsterai,
        .minimax
    ]

    public static func watchEntries(home: String) -> [WatchEntry] {
        [
            WatchEntry(path: join(home, ".codex", "sessions"), source: .codex),
            WatchEntry(path: join(home, ".codex", "archived_sessions"), source: .codex),
            WatchEntry(path: join(home, ".claude", "projects"), source: .claudeCode),
            WatchEntry(path: join(home, ".gemini", "tmp"), source: .geminiCli),
            WatchEntry(path: join(home, ".gemini", "antigravity"), source: .antigravity),
            WatchEntry(path: join(home, ".iflow", "projects"), source: .iflow),
            WatchEntry(path: join(home, ".qwen", "projects"), source: .qwen),
            WatchEntry(path: join(home, ".kimi", "sessions"), source: .kimi),
            WatchEntry(path: join(home, ".pi", "agent", "sessions"), source: .pi),
            WatchEntry(path: join(home, ".cline", "data", "tasks"), source: .cline)
        ]
    }

    public static func source(for path: String, home: String) -> SourceName? {
        let normalizedPath = normalize(path)
        return watchEntries(home: home).first { entry in
            normalizedPath == entry.path || normalizedPath.hasPrefix(entry.path + "/")
        }?.source
    }

    public static func isIgnored(_ path: String) -> Bool {
        let normalized = normalize(path)
        return normalized.range(of: #"/\.gemini/tmp/[^/]+/tool-outputs/"#, options: .regularExpression) != nil ||
            normalized.contains("/.vite-temp/") ||
            normalized.contains(".engram-tmp-") ||
            normalized.contains(".engram-move-tmp-") ||
            normalized.contains("/node_modules/") ||
            normalized.hasSuffix(".DS_Store")
    }

    public static func nonWatchableSources(from sources: Set<SourceName>) -> Set<SourceName> {
        sources.subtracting(watchedSources)
    }

    private static func join(_ parts: String...) -> String {
        parts.joined(separator: "/").replacingOccurrences(of: #"//+"#, with: "/", options: .regularExpression)
    }

    private static func normalize(_ path: String) -> String {
        path.replacingOccurrences(of: #"//+"#, with: "/", options: .regularExpression)
    }
}
