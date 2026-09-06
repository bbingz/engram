import Foundation

public struct CapturedSourceScan: Sendable {
    public let scan: IndexingScan
    /// The existing parser's selected source field, not the index identity.
    /// A Claude subagent's raw sessionId can identify its parent.
    public let rawSourceSessionID: String
}

protocol ModificationFilteredSessionAdapter: SessionAdapter {
    func listSessionLocators(modifiedSince: Date, fileManager: FileManager) async throws -> [String]
}

public enum SessionAdapterFactory {
    public static let maximumRecentDays = 7
    public static let maximumTransientRetryLocatorsPerSource = 100
    public static var maximumCapturedSourceBytes: Int64 { ParserLimits.default.maxFileBytes }

    public static func scanCapturedSource(
        physicalLocator: String,
        stagingRoot: String,
        logicalLocator: String,
        format: SourceMetadataProjection.Format
    ) async throws -> AdapterParseResult<CapturedSourceScan> {
        try Task.checkCancellation()
        let result: AdapterParseResult<CapturedSourceScan>
        switch format {
        case .claudeCode(let forceClaudeCodeSource):
            result = try ClaudeCodeAdapter.scanCapturedSource(
                physicalLocator: physicalLocator, stagingRoot: stagingRoot,
                logicalLocator: logicalLocator, forceClaudeCodeSource: forceClaudeCodeSource
            )
        case .codex:
            result = try CodexAdapter.scanCapturedSource(
                physicalLocator: physicalLocator, logicalLocator: logicalLocator
            )
        }
        try Task.checkCancellation()
        return result
    }

    private static func defaultClaudeCodeAdapter(
        homeDirectory: URL,
        profileResolver: ClaudeCodeProfileResolver? = nil,
        sourceHintCacheDirectory: URL? = nil
    ) -> ClaudeCodeAdapter {
        return ClaudeCodeAdapter(
            profileResolver: profileResolver ?? ClaudeCodeProfileResolver(
                homeDirectory: homeDirectory,
                settingsURL: homeDirectory.appendingPathComponent(".engram/settings.json")
            ),
            sourceHintCacheDirectory: sourceHintCacheDirectory
        )
    }

    public static func resolvedHomeDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        EngramUserDataDirectory.resolvedHomeDirectory(environment: environment)
    }

    public static func defaultAdapters() -> [any SessionAdapter] {
        defaultAdapters(homeDirectory: resolvedHomeDirectory())
    }

    public static func defaultAdapters(
        homeDirectory: URL,
        claudeCodeProfileResolver: ClaudeCodeProfileResolver? = nil
    ) -> [any SessionAdapter] {
        // Persist the derived-source (minimax/lobsterai) signature cache so a
        // cold scan skips head-sniffing every Claude file it has already seen.
        let cacheDirectory = homeDirectory
            .appendingPathComponent(".engram/cache", isDirectory: true)
        let claudeCode = defaultClaudeCodeAdapter(
            homeDirectory: homeDirectory,
            profileResolver: claudeCodeProfileResolver,
            sourceHintCacheDirectory: cacheDirectory
        )
        return [
            CodexAdapter(sessionsRoot: homeDirectory.appendingPathComponent(".codex/sessions").path),
            claudeCode,
            ClaudeCodeDerivedSourceAdapter(source: .minimax, base: claudeCode),
            ClaudeCodeDerivedSourceAdapter(source: .lobsterai, base: claudeCode),
            GeminiCliAdapter(
                tmpRoot: homeDirectory.appendingPathComponent(".gemini/tmp").path,
                projectsFile: homeDirectory.appendingPathComponent(".gemini/projects.json").path
            ),
            OpenCodeAdapter(dbPath: homeDirectory.appendingPathComponent(".local/share/opencode/opencode.db").path),
            IflowAdapter(projectsRoot: homeDirectory.appendingPathComponent(".iflow/projects").path),
            QwenAdapter(projectsRoot: homeDirectory.appendingPathComponent(".qwen/projects").path),
            QoderAdapter(projectsRoot: qoderProjectsRoot(homeDirectory: homeDirectory)),
            KimiAdapter(
                sessionsRoot: homeDirectory.appendingPathComponent(".kimi/sessions").path,
                kimiJsonPath: homeDirectory.appendingPathComponent(".kimi/kimi.json").path
            ),
            CommandCodeAdapter(projectsRoot: homeDirectory.appendingPathComponent(".commandcode/projects").path),
            ClineAdapter(tasksRoot: homeDirectory.appendingPathComponent(".cline/data/tasks").path),
            CursorAdapter(
                dbPath: homeDirectory.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path,
                cursorDataRoot: homeDirectory.appendingPathComponent(".cursor")
            ),
            VsCodeAdapter(workspaceStorageDir: homeDirectory.appendingPathComponent("Library/Application Support/Code/User/workspaceStorage").path),
            WindsurfAdapter(cacheDir: cacheDirectory.appendingPathComponent("windsurf").path),
            AntigravityAdapter(
                cacheDir: cacheDirectory.appendingPathComponent("antigravity").path,
                conversationsDir: homeDirectory.appendingPathComponent(".gemini/antigravity/conversations").path,
                cliBrainDir: homeDirectory.appendingPathComponent(".gemini/antigravity-cli/brain").path
            ),
            CopilotAdapter(sessionRoot: homeDirectory.appendingPathComponent(".copilot/session-state").path)
        ]
    }

    public static func qoderProjectsRoot(homeDirectory: URL) -> String {
        homeDirectory
            .appendingPathComponent(".qoder/projects", isDirectory: true)
            .standardizedFileURL
            .path
    }

    public static func recentCodexAdapters(
        now: Date = Date(),
        days: Int = 2,
        homeDirectory: URL? = nil
    ) -> [any SessionAdapter] {
        let homeDirectory = homeDirectory ?? resolvedHomeDirectory()
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"

        var roots: [String] = []
        var seen = Set<String>()
        let boundedDays = min(max(days, 1), maximumRecentDays)
        for offset in 0..<boundedDays {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let relativePath = formatter.string(from: date)
            guard seen.insert(relativePath).inserted else { continue }
            let root = homeDirectory
                .appendingPathComponent(".codex/sessions")
                .appendingPathComponent(relativePath)
                .path
            roots.append(root)
        }
        return roots.map { CodexAdapter(sessionsRoot: $0) }
    }

    public static func recentActiveAdapters(
        now: Date = Date(),
        days: Int = 2,
        priorTransientRetryLocators: [SourceName: [String]] = [:],
        maximumRetryLocatorsPerSource: Int = 20,
        homeDirectory: URL? = nil
    ) -> [any SessionAdapter] {
        let homeDirectory = homeDirectory ?? resolvedHomeDirectory()
        let boundedDays = min(max(days, 1), maximumRecentDays)
        let cutoff = now.addingTimeInterval(-Double(boundedDays) * 24 * 60 * 60)
        let claudeCode = defaultClaudeCodeAdapter(
            homeDirectory: homeDirectory
        )
        let fileBackedAdapters = defaultAdapters(homeDirectory: homeDirectory)
            .filter { $0.source != .codex && $0.source != .claudeCode && $0.source != .minimax && $0.source != .lobsterai }
        let claudeAdapters: [any SessionAdapter] = [
            claudeCode,
            ClaudeCodeDerivedSourceAdapter(source: .minimax, base: claudeCode),
            ClaudeCodeDerivedSourceAdapter(source: .lobsterai, base: claudeCode),
        ]
        let recentFileBacked: [any SessionAdapter] = (claudeAdapters + fileBackedAdapters).map { adapter in
            if let exact = adapter as? any ExactArchiveSourceAdapter {
                return RecentlyModifiedExactArchiveSourceAdapter(
                    base: exact,
                    modifiedSince: cutoff,
                    retryLocators: priorTransientRetryLocators[adapter.source] ?? [],
                    maximumRetryLocators: maximumRetryLocatorsPerSource
                )
            }
            return RecentlyModifiedSessionAdapter(base: adapter, modifiedSince: cutoff)
        }

        var adapters = recentCodexAdapters(
            now: now,
            days: boundedDays,
            homeDirectory: homeDirectory
        ) + recentFileBacked
        let codexRetries = RecentAdapterPolicy.boundedRetryLocators(
            priorTransientRetryLocators[.codex] ?? [],
            requestedLimit: maximumRetryLocatorsPerSource
        )
        if !codexRetries.isEmpty {
            adapters.append(
                ExactLocatorSubsetSessionAdapter(
                    base: CodexAdapter(
                        sessionsRoot: homeDirectory.appendingPathComponent(".codex/sessions").path
                    ),
                    locators: codexRetries
                )
            )
        }
        return adapters
    }

    /// Builds the only parser-facing adapter list allowed while exact archive
    /// capture is enabled. Non-exact sources remain unchanged. Exact sources
    /// are collapsed to one fail-closed adapter per source and can expose only
    /// locators captured successfully in this same maintenance cycle.
    public static func indexingAdapters(
        from adapters: [any SessionAdapter],
        capturedExactLocators: [SourceName: [String]]?,
        homeDirectory: URL? = nil
    ) -> [any SessionAdapter] {
        let homeDirectory = homeDirectory ?? resolvedHomeDirectory()
        guard let capturedExactLocators else { return adapters }

        var emittedExactSources = Set<SourceName>()
        return adapters.compactMap { adapter in
            guard let exact = adapter as? any ExactArchiveSourceAdapter else {
                return adapter
            }
            guard emittedExactSources.insert(adapter.source).inserted else {
                return nil
            }
            let locators = RecentAdapterPolicy.stableNormalizedLocators(
                capturedExactLocators[adapter.source] ?? []
            )
            guard !locators.isEmpty else { return nil }

            let parserBase: any SessionAdapter
            switch adapter.source {
            case .claudeCode where adapter is ClaudeCodeAdapter
                || adapter is RecentlyModifiedExactArchiveSourceAdapter:
                parserBase = defaultClaudeCodeAdapter(
                    homeDirectory: homeDirectory
                )
            case .codex where adapter is CodexAdapter:
                parserBase = CodexAdapter(
                    sessionsRoot: homeDirectory.appendingPathComponent(".codex/sessions").path
                )
            default:
                parserBase = exact
            }
            return CapturedLocatorIndexAdapter(base: parserBase, locators: locators)
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

    public func indexingInputIdentity(locator: String) -> IndexingInputIdentity? {
        base.indexingInputIdentity(locator: locator)
    }

    public func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        try await base.streamMessages(locator: locator, options: options)
    }

    public func streamMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> StreamMessagesResult {
        try await base.streamMessagesWithMetadata(locator: locator, options: options)
    }

    public func scanForIndexing(locator: String) async throws -> AdapterParseResult<IndexingScan> {
        try await base.scanForIndexing(locator: locator)
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

public final class RecentlyModifiedExactArchiveSourceAdapter: ExactArchiveSourceAdapter {
    public let source: SourceName

    private let base: any ExactArchiveSourceAdapter
    private let recentBase: RecentlyModifiedSessionAdapter
    private let retryLocators: [String]

    public init(
        base: any ExactArchiveSourceAdapter,
        modifiedSince: Date,
        retryLocators: [String] = [],
        maximumRetryLocators: Int = 20,
        fileManager: FileManager = .default
    ) {
        self.base = base
        self.source = base.source
        self.recentBase = RecentlyModifiedSessionAdapter(
            base: base,
            modifiedSince: modifiedSince,
            fileManager: fileManager
        )
        self.retryLocators = RecentAdapterPolicy.boundedRetryLocators(
            retryLocators,
            requestedLimit: maximumRetryLocators
        )
    }

    public func detect() async -> Bool {
        await base.detect()
    }

    public func listSessionLocators() async throws -> [String] {
        var locators = try await recentBase.listSessionLocators()
        var seen = Set(locators)
        for locator in retryLocators where seen.insert(locator).inserted {
            locators.append(locator)
        }
        return locators
    }

    public func archiveSourceDescriptor(locator: String) async throws -> ArchiveSourceDescriptor {
        try await base.archiveSourceDescriptor(locator: locator)
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

    public func streamMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> StreamMessagesResult {
        try await base.streamMessagesWithMetadata(locator: locator, options: options)
    }

    public func scanForIndexing(locator: String) async throws -> AdapterParseResult<IndexingScan> {
        try await base.scanForIndexing(locator: locator)
    }

    public func isAccessible(locator: String) async -> Bool {
        await base.isAccessible(locator: locator)
    }
}

private final class ExactLocatorSubsetSessionAdapter: ExactArchiveSourceAdapter {
    let source: SourceName

    private let base: any ExactArchiveSourceAdapter
    private let locators: [String]
    private let locatorSet: Set<String>

    init(base: any ExactArchiveSourceAdapter, locators: [String]) {
        self.base = base
        self.source = base.source
        self.locators = locators
        self.locatorSet = Set(locators)
    }

    func detect() async -> Bool { !locators.isEmpty }

    func listSessionLocators() async throws -> [String] {
        locators
    }

    func archiveSourceDescriptor(locator: String) async throws -> ArchiveSourceDescriptor {
        try requireAllowed(locator)
        return try await base.archiveSourceDescriptor(locator: locator)
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        try requireAllowed(locator)
        return try await base.parseSessionInfo(locator: locator)
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        try requireAllowed(locator)
        return try await base.streamMessages(locator: locator, options: options)
    }

    func streamMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> StreamMessagesResult {
        try requireAllowed(locator)
        return try await base.streamMessagesWithMetadata(locator: locator, options: options)
    }

    func scanForIndexing(locator: String) async throws -> AdapterParseResult<IndexingScan> {
        try requireAllowed(locator)
        return try await base.scanForIndexing(locator: locator)
    }

    func isAccessible(locator: String) async -> Bool {
        guard locatorSet.contains(locator) else { return false }
        return await base.isAccessible(locator: locator)
    }

    private func requireAllowed(_ locator: String) throws {
        guard locatorSet.contains(locator) else {
            throw ExactLocatorSubsetError.locatorNotAllowed
        }
    }
}

private enum ExactLocatorSubsetError: Error {
    case locatorNotAllowed
}

private final class CapturedLocatorIndexAdapter: SessionAdapter, @unchecked Sendable {
    let source: SourceName

    private let base: any SessionAdapter
    private let locators: [String]
    private let locatorSet: Set<String>

    init(base: any SessionAdapter, locators: [String]) {
        self.base = base
        self.source = base.source
        self.locators = locators
        self.locatorSet = Set(locators)
    }

    func detect() async -> Bool { !locators.isEmpty }
    func listSessionLocators() async throws -> [String] { locators }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        try requireAllowed(locator)
        return try await base.parseSessionInfo(locator: locator)
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        try requireAllowed(locator)
        return try await base.streamMessages(locator: locator, options: options)
    }

    func streamMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> StreamMessagesResult {
        try requireAllowed(locator)
        return try await base.streamMessagesWithMetadata(locator: locator, options: options)
    }

    func scanForIndexing(locator: String) async throws -> AdapterParseResult<IndexingScan> {
        try requireAllowed(locator)
        return try await base.scanForIndexing(locator: locator)
    }

    func isAccessible(locator: String) async -> Bool {
        guard locatorSet.contains(locator) else { return false }
        return await base.isAccessible(locator: locator)
    }

    private func requireAllowed(_ locator: String) throws {
        guard locatorSet.contains(locator) else {
            throw ExactLocatorSubsetError.locatorNotAllowed
        }
    }
}

private enum RecentAdapterPolicy {
    static func stableNormalizedLocators(_ locators: [String]) -> [String] {
        var seen = Set<String>()
        return locators.compactMap { locator in
            guard let normalized = ArchiveSourceDescriptor.normalizedAbsolutePath(locator),
                  normalized == locator,
                  seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }.sorted()
    }

    static func boundedRetryLocators(
        _ locators: [String],
        requestedLimit: Int
    ) -> [String] {
        let limit = min(
            max(requestedLimit, 0),
            SessionAdapterFactory.maximumTransientRetryLocatorsPerSource
        )
        guard limit > 0 else { return [] }

        var result: [String] = []
        var seen = Set<String>()
        for locator in locators {
            guard let normalized = ArchiveSourceDescriptor.normalizedAbsolutePath(locator),
                  normalized == locator,
                  seen.insert(normalized).inserted
            else {
                continue
            }
            result.append(normalized)
            if result.count == limit { break }
        }
        return result
    }
}
