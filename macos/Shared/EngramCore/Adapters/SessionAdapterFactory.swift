import Foundation

protocol ModificationFilteredSessionAdapter: SessionAdapter {
    func listSessionLocators(modifiedSince: Date, fileManager: FileManager) async throws -> [String]
}

protocol LocatorOwningSessionAdapter: SessionAdapter {
    func ownsLocator(_ locator: String) -> Bool
}

public enum SessionAdapterFactory {
    public static func defaultAdapters() -> [any SessionAdapter] {
        let claudeCode = ClaudeCodeAdapter()
        return [
            CodexAdapter(),
            GrokAdapter(),
            claudeCode,
            ClaudeCodeDerivedSourceAdapter(source: .minimax, base: claudeCode),
            ClaudeCodeDerivedSourceAdapter(source: .lobsterai, base: claudeCode),
        ] + claudeCodeProviderAdapters() + [
            GeminiCliAdapter(),
            OpenCodeAdapter(),
            IflowAdapter(),
            PiAdapter(),
            QwenAdapter(),
            QoderAdapter(),
            KimiAdapter(),
            CommandCodeAdapter(),
            ClineAdapter(),
            CursorAdapter(),
            VsCodeAdapter(),
            WindsurfAdapter(enableLiveSync: false),
            AntigravityAdapter(enableLiveSync: false),
            CopilotAdapter()
        ]
    }

    public static func adapter(
        for source: SourceName,
        locator: String,
        adapters: [any SessionAdapter] = defaultAdapters()
    ) -> (any SessionAdapter)? {
        let candidates = adapters.filter { $0.source == source }
        guard candidates.count > 1 else { return candidates.first }
        if let owner = candidates.first(where: { adapter in
            (adapter as? LocatorOwningSessionAdapter)?.ownsLocator(locator) == true
        }) {
            return owner
        }
        // No adapter positively owns this locator. Skip any adapter that
        // EXPLICITLY disowns it (a LocatorOwningSessionAdapter whose
        // ownsLocator returned false — e.g. a `~/.claude-<name>` provider-root
        // clone asked about a native locator). This keeps resolution correct
        // regardless of registration order, so a clone can never capture a
        // native locator just because it was registered first. Non-owning
        // adapters (native/derived that don't implement the protocol) remain
        // eligible.
        if let fallback = candidates.first(where: { adapter in
            guard let owning = adapter as? LocatorOwningSessionAdapter else { return true }
            return owning.ownsLocator(locator)
        }) {
            return fallback
        }
        return candidates.first
    }

    public static func recentCodexAdapters(now: Date = Date(), days: Int = 2) -> [any SessionAdapter] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"

        var roots: [String] = []
        var seen = Set<String>()
        for offset in 0..<max(days, 1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let relativePath = formatter.string(from: date)
            guard seen.insert(relativePath).inserted else { continue }
            let root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions")
                .appendingPathComponent(relativePath)
                .path
            roots.append(root)
        }
        return roots.map { CodexAdapter(sessionsRoot: $0) }
    }

    public static func recentActiveAdapters(now: Date = Date(), days: Int = 2) -> [any SessionAdapter] {
        let cutoff = now.addingTimeInterval(-Double(max(days, 1)) * 24 * 60 * 60)
        let claudeCode = ClaudeCodeAdapter()
        let fileBackedAdapters: [any SessionAdapter] = [
            GrokAdapter(),
            claudeCode,
            ClaudeCodeDerivedSourceAdapter(source: .minimax, base: claudeCode),
            ClaudeCodeDerivedSourceAdapter(source: .lobsterai, base: claudeCode),
        ] + claudeCodeProviderAdapters() + [
            GeminiCliAdapter(),
            OpenCodeAdapter(),
            IflowAdapter(),
            PiAdapter(),
            QwenAdapter(),
            QoderAdapter(),
            KimiAdapter(),
            CommandCodeAdapter(),
            ClineAdapter(),
            CursorAdapter(),
            VsCodeAdapter(),
            WindsurfAdapter(enableLiveSync: false),
            AntigravityAdapter(enableLiveSync: false),
            CopilotAdapter()
        ]
        return recentCodexAdapters(now: now, days: days) +
            fileBackedAdapters.map { RecentlyModifiedSessionAdapter(base: $0, modifiedSince: cutoff) }
    }

    private static func claudeCodeProviderAdapters() -> [any SessionAdapter] {
        [
            ("kimi", .kimi),
            ("minimax", .minimax),
            ("mimo", .mimo),
            ("mimosg", .mimo),
            ("qwen", .qwen),
            ("doubao", .doubao),
            ("glm", .glm),
            ("glmc", .glm),
            ("ds", .deepseek),
            ("dsc", .deepseek),
            ("openai", .codex),
        ].map { name, source in
            ClaudeCodeAdapter(
                source: source,
                projectsRoot: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude-\(name)/projects")
                    .path,
                originator: "Claude Code"
            )
        }
    }
}

public final class RecentlyModifiedSessionAdapter: SessionAdapter {
    public let source: SourceName

    private let base: any SessionAdapter
    private let modifiedSince: Date
    private let fileManager: FileManager

    public init(
        base: any SessionAdapter,
        modifiedSince: Date,
        fileManager: FileManager = .default
    ) {
        self.base = base
        self.source = base.source
        self.modifiedSince = modifiedSince
        self.fileManager = fileManager
    }

    public func detect() async -> Bool {
        await base.detect()
    }

    public func listSessionLocators() async throws -> [String] {
        if let filtered = base as? ModificationFilteredSessionAdapter {
            return try await filtered.listSessionLocators(
                modifiedSince: modifiedSince,
                fileManager: fileManager
            )
        }

        return try await base.listSessionLocators().filter { locator in
            guard let modifiedAt = try? Self.modifiedAt(locator: locator, fileManager: fileManager) else {
                return false
            }
            return modifiedAt >= modifiedSince
        }
    }

    public func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        try await base.parseSessionInfo(locator: locator)
    }

    public func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        try await base.streamMessages(locator: locator, options: options)
    }

    public func isAccessible(locator: String) async -> Bool {
        await base.isAccessible(locator: locator)
    }

    private static func modifiedAt(locator: String, fileManager: FileManager) throws -> Date {
        let attributes = try fileManager.attributesOfItem(atPath: backingFilePath(for: locator))
        return attributes[.modificationDate] as? Date ?? .distantPast
    }

    private static func backingFilePath(for locator: String) -> String {
        if let range = locator.range(of: "::", options: .backwards) {
            return String(locator[..<range.lowerBound])
        }
        if let range = locator.range(of: "?composer=") {
            return String(locator[..<range.lowerBound])
        }
        return locator
    }
}
