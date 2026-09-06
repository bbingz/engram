import Foundation

final class ClaudeCodeAdapter: SessionAdapter, TailIndexingSessionAdapter, ModificationFilteredSessionAdapter, ExactArchiveSourceAdapter, Sendable {
    let source: SourceName = .claudeCode

    private let profileResolutionProvider: (@Sendable () -> [ClaudeCodeProfile])?
    private let profileSnapshot: ClaudeCodeProfileSnapshot
    /// Roots from the same profile list that produced the latest keep-set.
    /// Empty until the first successful `listSessionLocators` so a reorder of
    /// the scan cannot prune against a stale or second profile read.
    private let lastListingRoots = ClaudeCodeEnumerationRoots()
    private let limits: ParserLimits
    private let sourceHintCache: ClaudeCodeSourceHintCache
    private static let sourceHintScanByteLimit = 1024 * 1024
    private static let sourceHintMaxLineBytes = 512 * 1024
    private static let sourceHintLineLimit = 64
    private static let sourceHintChunkSize = 64 * 1024

    /// Same profile snapshot as the keep-set from the last list call — not a
    /// second resolver pass (autoDiscover off must shrink roots with the list).
    var enumerationRoots: [String] { lastListingRoots.read() }

    /// - Parameter sourceHintCacheDirectory: When non-nil, the derived-source
    ///   signature cache is persisted here (keyed on path + mtime + size) so a
    ///   cold process skips head-sniffing every Claude file it has seen before.
    ///   `nil` keeps the cache purely in-memory (used by tests and transient
    ///   registries so they never touch `~/.engram`).
    init(
        projectsRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .path,
        limits: ParserLimits = .default,
        sourceHintCacheDirectory: URL? = nil
    ) {
        let canonicalRoot = URL(fileURLWithPath: projectsRoot, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        self.profileResolutionProvider = nil
        self.profileSnapshot = ClaudeCodeProfileSnapshot(
            profiles: [
                ClaudeCodeProfile(
                    id: "default-fixed",
                    displayName: "Default",
                    projectsRoot: canonicalRoot.path,
                    origin: .default,
                    available: JSONLAdapterSupport.isDirectory(canonicalRoot),
                    sourceReclamationAllowed: true
                ),
            ]
        )
        self.limits = limits
        self.sourceHintCache = ClaudeCodeSourceHintCache(directory: sourceHintCacheDirectory)
    }

    init(
        profileResolver: ClaudeCodeProfileResolver,
        limits: ParserLimits = .default,
        sourceHintCacheDirectory: URL? = nil
    ) {
        let provider: @Sendable () -> [ClaudeCodeProfile] = {
            profileResolver.resolve().profiles
        }
        self.profileResolutionProvider = provider
        self.profileSnapshot = ClaudeCodeProfileSnapshot(profiles: provider())
        self.limits = limits
        self.sourceHintCache = ClaudeCodeSourceHintCache(directory: sourceHintCacheDirectory)
    }

    init(
        profileResolutionProvider: @escaping @Sendable () -> [ClaudeCodeProfile],
        limits: ParserLimits = .default,
        sourceHintCacheDirectory: URL? = nil
    ) {
        self.profileResolutionProvider = profileResolutionProvider
        self.profileSnapshot = ClaudeCodeProfileSnapshot(profiles: profileResolutionProvider())
        self.limits = limits
        self.sourceHintCache = ClaudeCodeSourceHintCache(directory: sourceHintCacheDirectory)
    }

    func detect() async -> Bool {
        currentProfiles().contains { profile in
            JSONLAdapterSupport.isDirectory(URL(fileURLWithPath: profile.projectsRoot, isDirectory: true))
        }
    }

    func listSessionLocators() async throws -> [String] {
        // One profile refresh feeds both the keep-set and enumerationRoots.
        lastListingRoots.replace(with: [])
        let profiles = refreshProfilesForListing().filter(\.available)
        let listing = try await listSessionLocators(profiles: profiles)
        var locators: [String] = []
        for locator in listing.locators {
            try Task.checkCancellation()
            if Self.profile(for: locator, profiles: profiles)?.origin != .default {
                locators.append(locator)
                continue
            }
            let signature = Self.sourceHintSignature(locator: locator, fileManager: .default)
            let detected = await sourceHintCache.source(for: locator, signature: signature) {
                Self.detectSourceHint(locator: locator) ?? .claudeCode
            }
            if detected != .minimax, detected != .lobsterai {
                locators.append(locator)
            }
        }
        await sourceHintCache.flush()
        if listing.complete {
            lastListingRoots.replace(with: Self.enumerationRoots(from: profiles))
        }
        return locators
    }

    private struct LocatorListing {
        var locators: [String]
        var complete: Bool
    }

    private func listSessionLocators(profiles: [ClaudeCodeProfile]) async throws -> LocatorListing {
        try Task.checkCancellation()
        var locators = Set<String>()
        var complete = true
        for profile in profiles {
            try Task.checkCancellation()
            let projectsRoot = URL(fileURLWithPath: profile.projectsRoot, isDirectory: true)
            let listing = try await listSessionLocators(projectsRoot: projectsRoot)
            complete = complete && listing.complete
            for locator in listing.locators {
                let canonicalLocator = Self.canonicalURL(path: locator).path
                guard Self.isDescendant(canonicalLocator, of: profile.projectsRoot) else { continue }
                locators.insert(canonicalLocator)
            }
        }
        try Task.checkCancellation()
        return LocatorListing(locators: locators.sorted(), complete: complete)
    }

    private func listSessionLocators(projectsRoot: URL) async throws -> LocatorListing {
        var locators: [String] = []
        var complete = true
        let projects: [URL]
        do {
            projects = try JSONLAdapterSupport.requiredDirectChildren(of: projectsRoot, includingHidden: true)
        } catch {
            try Task.checkCancellation()
            return LocatorListing(locators: [], complete: false)
        }
        for projectURL in projects
            where JSONLAdapterSupport.isDirectory(projectURL)
        {
            try Task.checkCancellation()
            let entries: [URL]
            do {
                entries = try JSONLAdapterSupport.requiredDirectChildren(of: projectURL)
            } catch {
                try Task.checkCancellation()
                complete = false
                continue
            }
            for entryURL in entries {
                try Task.checkCancellation()
                if entryURL.pathExtension == "jsonl" {
                    locators.append(entryURL.path)
                    continue
                }

                let subagentsURL = entryURL.appendingPathComponent("subagents")
                guard JSONLAdapterSupport.isDirectory(subagentsURL) else { continue }
                do {
                    for subagentURL in try JSONLAdapterSupport.requiredDirectChildren(of: subagentsURL)
                        where subagentURL.pathExtension == "jsonl"
                    {
                        try Task.checkCancellation()
                        locators.append(subagentURL.path)
                    }
                } catch {
                    try Task.checkCancellation()
                    complete = false
                }

                // Row 32: Claude Code workflow runs nest agents under
                // subagents/workflows/wf_*/agent-*.jsonl. Direct children of
                // subagents/ are already collected above; only agent-*.jsonl
                // under wf_* dirs (never journal.jsonl or session-level
                // workflows/ siblings).
                let workflowsURL = subagentsURL.appendingPathComponent("workflows")
                guard JSONLAdapterSupport.isDirectory(workflowsURL) else { continue }
                let runs: [URL]
                do {
                    runs = try JSONLAdapterSupport.requiredDirectChildren(of: workflowsURL)
                } catch {
                    try Task.checkCancellation()
                    complete = false
                    continue
                }
                for runURL in runs
                    where JSONLAdapterSupport.isDirectory(runURL)
                    && runURL.lastPathComponent.hasPrefix("wf_")
                {
                    try Task.checkCancellation()
                    do {
                        for agentURL in try JSONLAdapterSupport.requiredDirectChildren(of: runURL)
                            where agentURL.pathExtension == "jsonl"
                            && agentURL.deletingPathExtension().lastPathComponent.hasPrefix("agent-")
                        {
                            try Task.checkCancellation()
                            locators.append(agentURL.path)
                        }
                    } catch {
                        try Task.checkCancellation()
                        complete = false
                    }
                }
            }
        }
        return LocatorListing(locators: locators, complete: complete)
    }

    func profile(for locator: String) -> ClaudeCodeProfile? {
        Self.profile(for: locator, profiles: currentProfiles())
    }

    func archiveSourceDescriptor(locator: String) async throws -> ArchiveSourceDescriptor {
        guard ArchiveSourceDescriptor.normalizedAbsolutePath(locator) != nil else {
            throw ArchiveSourceDescriptorError.invalidLocator(locator)
        }
        let sourceURL = Self.canonicalURL(path: locator)
        let profiles = currentProfiles()
        guard let profile = Self.profile(for: sourceURL.path, profiles: profiles) else {
            throw ArchiveSourceDescriptorError.pathOutsideRoot(
                path: sourceURL.path,
                root: profiles.map(\.projectsRoot).joined(separator: ":")
            )
        }
        let replayRoot = URL(fileURLWithPath: profile.projectsRoot, isDirectory: true)
        let relativePath = try ArchiveSourceDescriptor.relativePath(
            path: sourceURL,
            under: replayRoot
        )
        return try ArchiveSourceDescriptor.singleFile(
            locator: sourceURL.path,
            sourceURL: sourceURL,
            replayRelativePath: relativePath
        )
    }

    func listSessionLocators(modifiedSince: Date, fileManager: FileManager) async throws -> [String] {
        let filtered = try await listSessionLocators().filter {
            guard let modifiedAt = try? Self.modifiedAt(locator: $0, fileManager: fileManager) else { return false }
            return modifiedAt >= modifiedSince
        }
        // The full listing above stamped a domain; this result is a strict subset
        // of it. Leaving the domain stamped would let a caller prune everything
        // outside the recency window. Today the only caller is a wrapper that
        // reports no domain of its own, so this keeps the invariant on the object
        // rather than on the caller's discretion.
        lastListingRoots.replace(with: [])
        return filtered
    }

    func listDerivedSessionLocators(
        source: SourceName,
        modifiedSince: Date? = nil,
        fileManager: FileManager = .default
    ) async throws -> (locators: [String], enumerationRoots: [String]) {
        let profiles = refreshProfilesForListing()
        let defaultProfiles = profiles.filter { $0.available && $0.origin == .default }
        var locators: [String] = []
        let listing = try await listSessionLocators(profiles: defaultProfiles)
        for locator in listing.locators {
            try Task.checkCancellation()
            guard Self.profile(for: locator, profiles: profiles)?.origin == .default else {
                continue
            }
            if let modifiedSince {
                guard let modifiedAt = try? Self.modifiedAt(locator: locator, fileManager: fileManager),
                      modifiedAt >= modifiedSince
                else {
                    continue
                }
            }
            let signature = Self.sourceHintSignature(locator: locator, fileManager: fileManager)
            let detected = await sourceHintCache.source(for: locator, signature: signature) {
                Self.detectSourceHint(locator: locator) ?? .claudeCode
            }
            if detected == source {
                locators.append(locator)
            }
        }
        await sourceHintCache.flush()
        return (locators, listing.complete ? Self.enumerationRoots(from: defaultProfiles) : [])
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        guard let profile = profile(for: locator) else {
            return .failure(.unsupportedVirtualLocator)
        }
        do {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(
                locator: locator,
                limits: limits,
                reportFailures: true,
                countsTowardMessageLimit: {
                    Self.message(
                        from: $0,
                        seenUsageMessageIds: UsageMessageIdSet(),
                        unknownKinds: nil
                    ) != nil
                }
            )
            if let failure { return .failure(failure) }
            return Self.sessionInfo(
                from: objects,
                locator: locator,
                projectsRoot: profile.projectsRoot,
                forceClaudeCodeSource: profile.origin != .default
            )
        } catch let failure as ParserFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedJSON)
        }
    }

    /// Parse info and indexable messages from a single file read. System
    /// injections remain visible to transcript rendering, but are intentionally
    /// excluded here so they do not add indexing noise. `readObjects(reportFailures:)`
    /// surfaces the same failures the streamed path throws, so the indexer
    /// records an identical outcome on failure.
    func scanForIndexing(locator: String) async throws -> AdapterParseResult<IndexingScan> {
        guard let profile = profile(for: locator) else {
            return .failure(.unsupportedVirtualLocator)
        }
        switch try Self.scanFileForIndexing(
            physicalLocator: locator, logicalLocator: locator, projectsRoot: profile.projectsRoot,
            forceClaudeCodeSource: profile.origin != .default, limits: limits, strictRecords: false
        ) {
        case .success(let value): return .success(value.scan)
        case .failure(let failure): return .failure(failure)
        }
    }

    static func scanCapturedSource(
        physicalLocator: String, stagingRoot: String, logicalLocator: String, forceClaudeCodeSource: Bool
    ) throws -> AdapterParseResult<CapturedSourceScan> {
        try scanFileForIndexing(
            physicalLocator: physicalLocator, logicalLocator: logicalLocator, projectsRoot: stagingRoot,
            forceClaudeCodeSource: forceClaudeCodeSource, limits: .default, strictRecords: true
        )
    }

    private static func scanFileForIndexing(
        physicalLocator: String, logicalLocator: String, projectsRoot: String,
        forceClaudeCodeSource: Bool, limits: ParserLimits, strictRecords: Bool
    ) throws -> AdapterParseResult<CapturedSourceScan> {
        do {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(
                locator: physicalLocator,
                limits: limits,
                reportFailures: true,
                strictRecords: strictRecords,
                countsTowardMessageLimit: {
                    Self.message(
                        from: $0,
                        seenUsageMessageIds: UsageMessageIdSet(),
                        unknownKinds: nil
                    ) != nil
                }
            )
            if let failure, failure != .fileModifiedDuringParse { return .failure(failure) }
            // One sink feeds both gates so unknown kinds form a set, not a double count.
            let unknownKinds = UnknownRecordKindSink()
            let messages = Self.messages(from: objects, unknownKinds: unknownKinds)
            if failure == .fileModifiedDuringParse, messages.isEmpty {
                return .failure(.fileModifiedDuringParse)
            }
            let aggregate = Self.aggregateSessionInfo(from: objects, unknownKinds: unknownKinds)
            switch Self.sessionInfo(
                from: objects,
                locator: logicalLocator,
                projectsRoot: projectsRoot,
                forceClaudeCodeSource: forceClaudeCodeSource,
                unknownKinds: unknownKinds,
                physicalLocator: physicalLocator,
                aggregate: aggregate
            ) {
            case .failure(let reason):
                return .failure(reason)
            case .success(let info):
                let checkpoint = failure == nil
                    ? try JSONLAdapterSupport.checkpoint(locator: physicalLocator, limits: limits)
                    : nil
                let checkpointBoundaryHash = checkpoint?.parsedOffset == info.sizeBytes
                    ? checkpoint?.boundaryHash
                    : nil
                return .success(
                    CapturedSourceScan(
                        scan: IndexingScan(
                            info: info,
                            messages: messages,
                            parseFailure: failure,
                            checkpointParsedOffset: checkpoint?.parsedOffset,
                            checkpointBoundaryHash: checkpointBoundaryHash,
                            unknownRecordKinds: unknownKinds.kinds
                        ),
                        rawSourceSessionID: aggregate.sessionId
                    )
                )
            }
        } catch is CancellationError where strictRecords {
            throw CancellationError()
        } catch let failure as ParserFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedJSON)
        }
    }

    func scanTailForIndexing(
        locator: String,
        from parsedOffset: Int64,
        expectedBoundaryHash: String
    ) async throws -> IndexingTailScanResult {
        guard let profile = profile(for: locator) else {
            return .failure(.unsupportedVirtualLocator)
        }
        do {
            let countsTowardMessageLimit = Self.makeMessageTransform()
            let result = try JSONLAdapterSupport.readTailObjects(
                locator: locator,
                from: parsedOffset,
                expectedBoundaryHash: expectedBoundaryHash,
                limits: limits,
                countsTowardMessageLimit: { countsTowardMessageLimit($0) != nil }
            )
            guard !result.boundaryHash.isEmpty else { return .fallback }
            if let failure = result.failure { return .failure(failure) }
            let messages = Self.messages(from: result.objects, unknownKinds: nil)
            guard !messages.isEmpty else { return .fallback }
            let aggregate = Self.aggregateSessionInfo(from: result.objects, unknownKinds: nil)
            return .success(
                IndexingTailScan(
                    infoDelta: IndexingTailInfoDelta(
                        id: aggregate.id(locator: locator, projectsRoot: profile.projectsRoot),
                        source: profile.origin == .default
                            ? aggregate.source(locator: locator)
                            : .claudeCode,
                        endTime: aggregate.endTime.isEmpty ? nil : aggregate.endTime,
                        model: aggregate.detectedModel.isEmpty ? nil : aggregate.detectedModel,
                        messageCount: aggregate.messageCount,
                        userMessageCount: aggregate.userCount,
                        assistantMessageCount: aggregate.assistantCount,
                        toolMessageCount: aggregate.toolCount,
                        systemMessageCount: aggregate.systemCount,
                        firstVisibleRole: messages.first?.role
                    ),
                    messages: messages,
                    parsedOffset: result.parsedOffset,
                    boundaryHash: result.boundaryHash
                )
            )
        } catch let failure as ParserFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedJSON)
        }
    }

    private static func sessionInfo(
        from objects: [JSONLAdapterSupport.JSONObject],
        locator: String,
        projectsRoot: String,
        forceClaudeCodeSource: Bool,
        unknownKinds: UnknownRecordKindSink? = nil,
        physicalLocator: String? = nil,
        aggregate suppliedAggregate: SessionInfoAggregate? = nil
    ) -> AdapterParseResult<NormalizedSessionInfo> {
        let aggregate = suppliedAggregate ?? aggregateSessionInfo(from: objects, unknownKinds: unknownKinds)
        guard aggregate.messageCount > 0 else {
            return objects.isEmpty ? .failure(.malformedJSON) : .failure(.noVisibleMessages)
        }
        let subagent = SubagentTranscriptPath.layout(locator: physicalLocator ?? locator, projectsRoot: projectsRoot)
        guard let id = aggregate.id(locator: physicalLocator ?? locator, projectsRoot: projectsRoot) else {
            return .failure(.malformedJSON)
        }

        return .success(
            NormalizedSessionInfo(
                id: id,
                source: forceClaudeCodeSource
                    ? .claudeCode
                    : aggregate.source(locator: locator) ?? .claudeCode,
                startTime: aggregate.startTime,
                endTime: aggregate.endTime != aggregate.startTime ? aggregate.endTime : nil,
                cwd: aggregate.cwd,
                project: Self.projectName(fromCwd: aggregate.cwd),
                model: aggregate.detectedModel.isEmpty ? nil : aggregate.detectedModel,
                messageCount: aggregate.messageCount,
                userMessageCount: aggregate.userCount,
                assistantMessageCount: aggregate.assistantCount,
                toolMessageCount: aggregate.toolCount,
                systemMessageCount: aggregate.systemCount,
                summary: aggregate.firstUserText.isEmpty ? nil : aggregate.firstUserText,
                filePath: locator,
                sizeBytes: JSONLAdapterSupport.fileSize(locator: physicalLocator ?? locator),
                indexedAt: nil,
                agentRole: subagent == nil ? nil : "subagent",
                originator: forceClaudeCodeSource ? "claude-code" : nil,
                origin: nil,
                summaryMessageCount: nil,
                tier: nil,
                qualityScore: nil,
                parentSessionId: subagent?.parentSessionId,
                suggestedParentId: nil
            )
        )
    }

    private struct SessionInfoAggregate {
        var sessionId = ""
        var agentId = ""
        var cwd = ""
        var startTime = ""
        var endTime = ""
        var userCount = 0
        var assistantCount = 0
        var toolCount = 0
        var systemCount = 0
        var firstUserText = ""
        var detectedModel = ""

        var messageCount: Int {
            userCount + assistantCount + toolCount
        }

        func id(locator: String, projectsRoot: String) -> String? {
            guard !sessionId.isEmpty else { return nil }
            let subagent = SubagentTranscriptPath.layout(locator: locator, projectsRoot: projectsRoot)
            // R1.P1.identity-key-collision: empty agentId must not fall back to
            // parent sessionId (ON CONFLICT(id) would clobber the parent row).
            if let subagent {
                return ClaudeCodeAdapter.stableSubagentFallbackId(
                    parentSessionId: subagent.parentSessionId,
                    relativePath: subagent.relativePath
                )
            }
            return sessionId
        }

        func source(locator: String) -> SourceName? {
            guard !sessionId.isEmpty else { return nil }
            return ClaudeCodeAdapter.detectSource(model: detectedModel, filePath: locator)
        }
    }

    /// Lifecycle / sidecar record kinds we deliberately drop (not parse failures).
    /// Seeded from live corpus + committed claude-code fixtures (mirror row 23).
    private static let knownIgnoredRecordKinds: Set<String> = [
        "agent-name", "ai-title", "attachment", "file-history-delta",
        "file-history-snapshot", "last-prompt", "mode", "permission-mode",
        "pr-link", "queue-operation", "result", "started", "summary", "system",
    ]

    private static func aggregateSessionInfo(
        from objects: [JSONLAdapterSupport.JSONObject],
        unknownKinds: UnknownRecordKindSink?
    ) -> SessionInfoAggregate {
        var aggregate = SessionInfoAggregate()
        var metadata = SourceMetadataProjection(format: .claudeCode(forceClaudeCodeSource: false), locator: "")
        for object in objects {
            metadata.consume(object)
            if aggregate.agentId.isEmpty, let value = JSONLAdapterSupport.string(object["agentId"]) {
                aggregate.agentId = value
            }
            guard let type = JSONLAdapterSupport.string(object["type"]),
                  type == "user" || type == "assistant"
            else {
                noteUnknownRecordKind(JSONLAdapterSupport.string(object["type"]), into: unknownKinds)
                continue
            }

            if aggregate.startTime.isEmpty, let value = JSONLAdapterSupport.string(object["timestamp"]) {
                aggregate.startTime = value
            }
            if let value = JSONLAdapterSupport.string(object["timestamp"]) {
                aggregate.endTime = value
            }

            let message = JSONLAdapterSupport.object(object["message"])
            if type == "assistant" {
                aggregate.assistantCount += 1
            } else if Self.isToolResult(message?["content"]) {
                // Count a tool_result user record only when it surfaces
                // non-empty content, matching message(from:) which drops
                // empty tool results from the streamed transcript.
                if !Self.extractContent(message?["content"]).isEmpty {
                    aggregate.toolCount += 1
                }
            } else {
                let text = Self.extractContent(message?["content"])
                if Self.isSystemInjection(text) {
                    aggregate.systemCount += 1
                } else {
                    aggregate.userCount += 1
                    if aggregate.firstUserText.isEmpty { aggregate.firstUserText = text }
                }
            }
        }
        aggregate.sessionId = metadata.nativeSessionID ?? ""
        aggregate.cwd = metadata.cwd ?? ""
        aggregate.detectedModel = metadata.model ?? ""
        return aggregate
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        guard profile(for: locator) != nil else {
            throw ParserFailure.unsupportedVirtualLocator
        }
        let messages = try JSONLAdapterSupport.windowedMessages(
            locator: locator,
            options: options,
            limits: limits,
            countsTowardMessageLimit: { $0.role != .system },
            transform: Self.makeMessageTransform(includeSystemInjections: true)
        )
        return JSONLAdapterSupport.stream(messages)
    }

    func streamMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> StreamMessagesResult {
        guard profile(for: locator) != nil else {
            throw ParserFailure.unsupportedVirtualLocator
        }
        let result = try JSONLAdapterSupport.windowedMessagesWithMetadata(
            locator: locator,
            options: options,
            limits: limits,
            countsTowardMessageLimit: { $0.role != .system },
            transform: Self.makeMessageTransform(includeSystemInjections: true)
        )
        return JSONLAdapterSupport.stream(result)
    }

    func isAccessible(locator: String) async -> Bool {
        profile(for: locator) != nil && JSONLAdapterSupport.fileExists(locator)
    }

    private func currentProfiles() -> [ClaudeCodeProfile] {
        profileSnapshot.read()
    }

    private func refreshProfilesForListing() -> [ClaudeCodeProfile] {
        guard let profileResolutionProvider else {
            return currentProfiles()
        }
        let profiles = profileResolutionProvider()
        profileSnapshot.replace(with: profiles)
        return profiles
    }

    private static func profile(
        for locator: String,
        profiles: [ClaudeCodeProfile]
    ) -> ClaudeCodeProfile? {
        guard ArchiveSourceDescriptor.normalizedAbsolutePath(locator) != nil else { return nil }
        let canonicalLocator = canonicalURL(path: locator).path
        return profiles
            .filter { isDescendant(canonicalLocator, of: $0.projectsRoot) }
            .max { lhs, rhs in
                let lhsCount = URL(fileURLWithPath: lhs.projectsRoot).pathComponents.count
                let rhsCount = URL(fileURLWithPath: rhs.projectsRoot).pathComponents.count
                if lhsCount != rhsCount { return lhsCount < rhsCount }
                return lhs.projectsRoot < rhs.projectsRoot
            }
    }

    private static func canonicalURL(path: String) -> URL {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private static func isDescendant(_ path: String, of root: String) -> Bool {
        let pathComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let rootComponents = URL(fileURLWithPath: root).standardizedFileURL.pathComponents
        return pathComponents.count > rootComponents.count
            && Array(pathComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func projectName(fromCwd cwd: String) -> String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    /// Stable primary key for `/subagents/` transcripts. Claude reuses agentId
    /// across workflow runs, so the path relative to `subagents/` is the unique
    /// identity namespace; it also cannot collide with the parent row.
    static func stableSubagentFallbackId(parentSessionId: String, locator: String) -> String {
        let components = URL(fileURLWithPath: locator).standardizedFileURL.pathComponents
        let relativePath: String
        if let subagentsIndex = components.lastIndex(of: "subagents"),
           subagentsIndex + 1 < components.count {
            relativePath = components[(subagentsIndex + 1)...].joined(separator: "/")
        } else {
            relativePath = URL(fileURLWithPath: locator).lastPathComponent
        }
        return stableSubagentFallbackId(parentSessionId: parentSessionId, relativePath: relativePath)
    }

    private static func stableSubagentFallbackId(parentSessionId: String, relativePath: String) -> String {
        let pathKey = relativePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let leaf = pathKey.isEmpty ? "unknown" : pathKey
        return "sub:\(parentSessionId):\(leaf)"
    }

    static func detectSource(model: String, filePath: String? = nil) -> SourceName {
        SourceMetadataProjection.claudeSource(model: model, filePath: filePath)
    }

    static func detectSourceHint(locator: String) -> SourceName? {
        if SourceMetadataProjection.hasLobsterAIPathComponent(locator) { return .lobsterai }
        guard let hint = sourceHint(locator: locator), hint.sawRecognizedRecord else { return nil }
        guard let model = hint.model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty
        else {
            return .claudeCode
        }
        return detectSource(model: model)
    }

    private static func sourceHintSignature(
        locator: String,
        fileManager: FileManager
    ) -> ClaudeCodeSourceHintCache.Signature? {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: locator)
            let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            return ClaudeCodeSourceHintCache.Signature(modifiedAt: modifiedAt, size: size)
        } catch {
            return nil
        }
    }

    private struct SourceHintScan {
        let model: String?
        let sawRecognizedRecord: Bool
    }

    private struct SourceHintRecord {
        let model: String?
    }

    private static func sourceHint(locator: String) -> SourceHintScan? {
        let url = URL(fileURLWithPath: locator)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var buffer = Data()
        var scannedBytes = 0
        var scannedLines = 0
        var droppingOversizedLine = false
        var reachedEOF = false
        var sawRecognizedRecord = false

        while scannedBytes < sourceHintScanByteLimit && scannedLines < sourceHintLineLimit {
            let remaining = sourceHintScanByteLimit - scannedBytes
            let chunk = handle.readData(ofLength: min(sourceHintChunkSize, remaining))
            if chunk.isEmpty {
                reachedEOF = true
                break
            }
            scannedBytes += chunk.count

            if droppingOversizedLine {
                guard let newlineIndex = chunk.firstIndex(of: UInt8(ascii: "\n")) else { continue }
                droppingOversizedLine = false
                buffer = Data(chunk[(newlineIndex + 1)...])
            } else {
                buffer.append(chunk)
            }

            while scannedLines < sourceHintLineLimit,
                  let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[(newlineIndex + 1)...])
                scannedLines += 1
                if let record = sourceHintRecord(inLine: lineData) {
                    sawRecognizedRecord = true
                    if let model = record.model {
                        return SourceHintScan(model: model, sawRecognizedRecord: true)
                    }
                }
            }

            if buffer.count > sourceHintMaxLineBytes {
                buffer.removeAll(keepingCapacity: false)
                droppingOversizedLine = true
            }
        }

        if reachedEOF,
           !buffer.isEmpty,
           scannedLines < sourceHintLineLimit,
           let record = sourceHintRecord(inLine: buffer) {
            sawRecognizedRecord = true
            if let model = record.model {
                return SourceHintScan(model: model, sawRecognizedRecord: true)
            }
        }
        return SourceHintScan(model: nil, sawRecognizedRecord: sawRecognizedRecord)
    }

    private static func sourceHintRecord(inLine lineData: Data) -> SourceHintRecord? {
        guard lineData.count <= sourceHintMaxLineBytes,
              let text = String(data: lineData, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespaces).isEmpty,
              let object = JSONLAdapterSupport.parseObject(text)
        else {
            return nil
        }
        let model = modelHint(in: object)
        let type = JSONLAdapterSupport.string(object["type"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard model != nil || type?.isEmpty == false else { return nil }
        return SourceHintRecord(model: model)
    }

    private static func modelHint(in object: JSONLAdapterSupport.JSONObject) -> String? {
        if let model = JSONLAdapterSupport.string(object["model"]) { return model }
        if let message = JSONLAdapterSupport.object(object["message"]),
           let model = JSONLAdapterSupport.string(message["model"]) {
            return model
        }
        if let payload = JSONLAdapterSupport.object(object["payload"]),
           let model = JSONLAdapterSupport.string(payload["model"]) {
            return model
        }
        return nil
    }

    private static func modifiedAt(locator: String, fileManager: FileManager) throws -> Date {
        let attributes = try fileManager.attributesOfItem(atPath: locator)
        return attributes[.modificationDate] as? Date ?? .distantPast
    }

    static func decodeCwd(_ encoded: String) -> String {
        encoded
            .replacingOccurrences(of: "--", with: "\u{0}")
            .replacingOccurrences(of: "-", with: "/")
            .replacingOccurrences(of: "\u{0}", with: "-")
    }

    private final class UsageMessageIdSet {
        var ids = Set<String>()
    }

    /// Accumulates unknown dropped record kinds for `scanForIndexing` only.
    private final class UnknownRecordKindSink: @unchecked Sendable {
        var kinds = Set<String>()
    }

    private static func noteUnknownRecordKind(_ type: String?, into sink: UnknownRecordKindSink?) {
        guard let sink, let type, !type.isEmpty else { return }
        if type == "user" || type == "assistant" { return }
        if knownIgnoredRecordKinds.contains(type) { return }
        sink.kinds.insert(type)
    }

    /// Stateful transform so response-level usage is attached only once per
    /// non-empty Claude `message.id` (content blocks still stream separately).
    /// Streaming paths discard unknown-kind accumulation (no IndexingScan).
    private static func makeMessageTransform(
        includeSystemInjections: Bool = false
    ) -> (JSONLAdapterSupport.JSONObject) -> NormalizedMessage? {
        let seenUsageMessageIds = UsageMessageIdSet()
        return { object in
            message(
                from: object,
                seenUsageMessageIds: seenUsageMessageIds,
                unknownKinds: nil,
                includeSystemInjections: includeSystemInjections
            )
        }
    }

    private static func messages(
        from objects: [JSONLAdapterSupport.JSONObject],
        unknownKinds: UnknownRecordKindSink?
    ) -> [NormalizedMessage] {
        let seenUsageMessageIds = UsageMessageIdSet()
        return objects.compactMap {
            message(from: $0, seenUsageMessageIds: seenUsageMessageIds, unknownKinds: unknownKinds)
        }
    }

    private static func message(
        from object: JSONLAdapterSupport.JSONObject,
        seenUsageMessageIds: UsageMessageIdSet,
        unknownKinds: UnknownRecordKindSink?,
        includeSystemInjections: Bool = false
    ) -> NormalizedMessage? {
        guard let type = JSONLAdapterSupport.string(object["type"]),
              type == "user" || type == "assistant"
        else {
            noteUnknownRecordKind(JSONLAdapterSupport.string(object["type"]), into: unknownKinds)
            return nil
        }

        let message = JSONLAdapterSupport.object(object["message"])
        let rawContent = message?["content"]
        let toolCalls = toolCalls(from: rawContent)
        let content = extractContent(rawContent)
        // A user record that only carries a tool_result is a tool message, not
        // a user turn. Drop it when it surfaces no content so the streamed
        // transcript matches parseSessionInfo's counts.
        let isToolResultRecord = type == "user" && isToolResult(rawContent)
        let isSystemInjectionRecord = type == "user" && !isToolResultRecord && isSystemInjection(content)
        if isSystemInjectionRecord, !includeSystemInjections {
            return nil
        }
        if isToolResultRecord, content.isEmpty {
            return nil
        }
        let role: NormalizedMessageRole = isSystemInjectionRecord
            ? .system
            : (isToolResultRecord ? .tool : (type == "user" ? .user : .assistant))
        var usage = JSONLAdapterSupport.usage(from: JSONLAdapterSupport.object(message?["usage"]))
        if role == .assistant,
           let messageId = JSONLAdapterSupport.string(message?["id"]),
           !messageId.isEmpty,
           usage != nil
        {
            if seenUsageMessageIds.ids.contains(messageId) {
                usage = nil
            } else {
                seenUsageMessageIds.ids.insert(messageId)
            }
        }
        return NormalizedMessage(
            role: role,
            content: content,
            timestamp: JSONLAdapterSupport.string(object["timestamp"]),
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            usage: usage
        )
    }

    private static func isSystemInjection(_ text: String) -> Bool {
        SystemMessageClassifier.classify(content: text, source: "claude-code") != .none
    }

    private static func isToolResult(_ content: Any?) -> Bool {
        guard let content = JSONLAdapterSupport.array(content) else { return false }
        return content.contains { item in
            JSONLAdapterSupport.string(JSONLAdapterSupport.object(item)?["type"]) == "tool_result"
        }
    }

    private static func extractContent(_ content: Any?) -> String {
        if let string = content as? String { return string }
        guard let content = JSONLAdapterSupport.array(content) else { return "" }

        var parts: [String] = []
        var thinkingFallback = ""
        for item in content {
            guard let object = JSONLAdapterSupport.object(item),
                  let type = JSONLAdapterSupport.string(object["type"])
            else {
                continue
            }

            if type == "text", let text = JSONLAdapterSupport.string(object["text"]) {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text != "Tool loaded." {
                    parts.append(text)
                }
            } else if type == "thinking", thinkingFallback.isEmpty,
                      let thinking = JSONLAdapterSupport.string(object["thinking"]) {
                thinkingFallback = thinking
            } else if type == "tool_use" {
                let formatted = formatToolUse(object)
                if !formatted.isEmpty { parts.append(formatted) }
            } else if type == "tool_result" {
                let formatted = formatToolResult(object)
                if !formatted.isEmpty { parts.append(formatted) }
            } else if type == "image" {
                let source = JSONLAdapterSupport.object(object["source"])
                let mediaType = JSONLAdapterSupport.string(source?["media_type"]) ?? "image/unknown"
                let dataLength = JSONLAdapterSupport.string(source?["data"])?.count ?? 0
                let sizeKB = Int((Double(dataLength) * 0.75 / 1024.0).rounded())
                parts.append("[Image: \(mediaType), ~\(sizeKB) KB]")
            }
        }

        let nonEmpty = parts.filter { !$0.isEmpty }
        if !nonEmpty.isEmpty { return nonEmpty.joined(separator: "\n\n") }
        return thinkingFallback
    }

    private static let noiseTools: Set<String> = [
        "ToolSearch",
        "ExitPlanMode",
        "EnterPlanMode",
        "Skill",
        "TodoWrite",
        "TodoRead",
        "TaskCreate",
        "TaskUpdate",
        "TaskGet",
        "TaskList"
    ]

    private static func toolCalls(from content: Any?) -> [NormalizedToolCall] {
        guard let content = JSONLAdapterSupport.array(content) else { return [] }
        return content.compactMap { item in
            guard let object = JSONLAdapterSupport.object(item),
                  JSONLAdapterSupport.string(object["type"]) == "tool_use",
                  let name = JSONLAdapterSupport.string(object["name"])
            else {
                return nil
            }
            let input = object["input"].flatMap { JSONLAdapterSupport.jsonString($0, limit: 500) }
            return NormalizedToolCall(name: name, input: input, output: nil)
        }
    }

    private static func formatToolUse(_ object: JSONLAdapterSupport.JSONObject) -> String {
        guard let name = JSONLAdapterSupport.string(object["name"]) else { return "" }
        if noiseTools.contains(name) { return "" }
        guard let input = JSONLAdapterSupport.object(object["input"]) else { return "`\(name)`" }
        if name == "AskUserQuestion",
           let questions = JSONLAdapterSupport.array(input["questions"]) as? [JSONLAdapterSupport.JSONObject] {
            return formatAskUserQuestion(questions)
        }

        let summary = summarizeToolInput(name: name, input: input)
        return summary.isEmpty ? "`\(name)`" : "`\(name)`: \(summary)"
    }

    private static func formatAskUserQuestion(_ questions: [JSONLAdapterSupport.JSONObject]) -> String {
        questions.map { question in
            let header = JSONLAdapterSupport.string(question["header"]).map { "**\($0)**\n" } ?? ""
            let body = JSONLAdapterSupport.string(question["question"]) ?? ""
            guard let options = JSONLAdapterSupport.array(question["options"]) else {
                return header + body
            }
            let optionLines = options.enumerated().compactMap { index, item -> String? in
                guard let option = JSONLAdapterSupport.object(item),
                      let label = JSONLAdapterSupport.string(option["label"])
                else {
                    return nil
                }
                let description = JSONLAdapterSupport.string(option["description"]).map { " - \($0)" } ?? ""
                return "  \(index + 1). \(label)\(description)"
            }
            return header + body + (optionLines.isEmpty ? "" : "\n" + optionLines.joined(separator: "\n"))
        }
        .joined(separator: "\n\n")
    }

    private static func formatToolResult(_ object: JSONLAdapterSupport.JSONObject) -> String {
        let content = object["content"]
        if let string = content as? String {
            return string.hasPrefix("User has answered") ? string : ""
        }
        guard let content = JSONLAdapterSupport.array(content) else { return "" }
        let texts = content.compactMap { item -> String? in
            guard let object = JSONLAdapterSupport.object(item),
                  JSONLAdapterSupport.string(object["type"]) == "text"
            else {
                return nil
            }
            return JSONLAdapterSupport.string(object["text"])
        }
        let joined = texts.joined(separator: "\n")
        return joined.hasPrefix("User has answered") ? joined : ""
    }

    private static func summarizeToolInput(name: String, input: JSONLAdapterSupport.JSONObject) -> String {
        switch name {
        case "Read", "Write", "Edit":
            return JSONLAdapterSupport.string(input["file_path"]) ?? ""
        case "Bash":
            return String((JSONLAdapterSupport.string(input["command"]) ?? "").prefix(120))
        case "Glob", "Grep":
            return JSONLAdapterSupport.string(input["pattern"]) ?? ""
        case "Agent":
            return JSONLAdapterSupport.string(input["description"]) ?? ""
        default:
            return ""
        }
    }

}

public extension SessionAdapterFactory {
    static func detectClaudeCodeSourceHint(locator: String) -> SourceName? {
        ClaudeCodeAdapter.detectSourceHint(locator: locator)
    }
}

private actor ClaudeCodeSourceHintCache {
    struct Signature: Equatable, Sendable {
        let modifiedAt: TimeInterval  // timeIntervalSince1970
        let size: Int64
    }

    private struct Entry: Sendable {
        let signature: Signature
        let source: SourceName
    }

    /// On-disk format. Bump `formatVersion` to invalidate every persisted entry
    /// when the sniffing logic or record shape changes.
    private struct DiskEntry: Codable {
        let modifiedAt: TimeInterval
        let size: Int64
        let source: String
    }

    private struct DiskCache: Codable {
        let version: Int
        let entries: [String: DiskEntry]
    }

    private static let formatVersion = 1

    private let fileURL: URL?
    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var dirty = false

    init(directory: URL?) {
        self.fileURL = directory?.appendingPathComponent("claude-source-hints.json")
    }

    func source(
        for locator: String,
        signature: Signature?,
        resolve: @Sendable () -> SourceName
    ) -> SourceName {
        loadIfNeeded()
        if let signature,
           let entry = entries[locator],
           entry.signature == signature {
            return entry.source
        }

        let source = resolve()
        if let signature {
            entries[locator] = Entry(signature: signature, source: source)
        } else {
            entries.removeValue(forKey: locator)
        }
        dirty = true
        return source
    }

    /// Persist the current entries. No-op when persistence is disabled
    /// (in-memory cache) or nothing changed since the last write.
    func flush() {
        guard let fileURL, dirty else { return }
        let disk = DiskCache(
            version: Self.formatVersion,
            entries: entries.mapValues {
                DiskEntry(modifiedAt: $0.signature.modifiedAt, size: $0.signature.size, source: $0.source.rawValue)
            }
        )
        guard let data = try? JSONEncoder().encode(disk) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
        dirty = false
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let disk = try? JSONDecoder().decode(DiskCache.self, from: data),
              disk.version == Self.formatVersion
        else {
            return
        }
        for (locator, entry) in disk.entries {
            guard let source = SourceName(rawValue: entry.source) else { continue }
            entries[locator] = Entry(
                signature: Signature(modifiedAt: entry.modifiedAt, size: entry.size),
                source: source
            )
        }
    }
}

private final class ClaudeCodeProfileSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var profiles: [ClaudeCodeProfile]

    init(profiles: [ClaudeCodeProfile]) {
        self.profiles = profiles
    }

    func read() -> [ClaudeCodeProfile] {
        lock.lock()
        defer { lock.unlock() }
        return profiles
    }

    func replace(with profiles: [ClaudeCodeProfile]) {
        lock.lock()
        defer { lock.unlock() }
        self.profiles = profiles
    }
}

/// Thread-safe last-list enumeration roots for `ClaudeCodeAdapter`.
private final class ClaudeCodeEnumerationRoots: @unchecked Sendable {
    private let lock = NSLock()
    private var roots: [String] = []

    func read() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return roots
    }

    func replace(with roots: [String]) {
        lock.lock()
        defer { lock.unlock() }
        self.roots = roots
    }
}

extension ClaudeCodeAdapter {
    /// Prune domain for a set of profiles: the resolved root **and** every
    /// spelling that resolved to it. Enumeration emits canonical locators only,
    /// so a symlink-spelled row is never in the keep-set; without its spelling in
    /// the domain it can never be pruned either, and it accumulates forever.
    /// On a layout of real directories the two coincide and dedupe to one.
    fileprivate static func enumerationRoots(from profiles: [ClaudeCodeProfile]) -> [String] {
        var seen = Set<String>()
        var roots: [String] = []
        for profile in profiles {
            // The declared spellings may repeat the canonical root; `seen`
            // preserves canonical-first order while removing that duplicate.
            for candidate in [canonicalURL(path: profile.projectsRoot).path] + profile.declaredProjectsRoots {
                var path = candidate
                while path.count > 1, path.hasSuffix("/") { path.removeLast() }
                guard !path.isEmpty, seen.insert(path).inserted else { continue }
                roots.append(path)
            }
        }
        return roots
    }
}

final class ClaudeCodeDerivedSourceAdapter:
    SessionAdapter, TailIndexingSessionAdapter, ModificationFilteredSessionAdapter, Sendable
{
    let source: SourceName
    private let base: ClaudeCodeAdapter
    /// Separate from the base's holder: three adapters share one base instance in
    /// `defaultAdapters()`, and their domains differ.
    private let lastListingRoots = ClaudeCodeEnumerationRoots()

    init(source: SourceName, base: ClaudeCodeAdapter) {
        precondition(source == .minimax || source == .lobsterai)
        self.source = source
        self.base = base
    }

    convenience init(
        source: SourceName,
        projectsRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .path,
        limits: ParserLimits = .default,
        sourceHintCacheDirectory: URL? = nil
    ) {
        self.init(
            source: source,
            base: ClaudeCodeAdapter(
                projectsRoot: projectsRoot,
                limits: limits,
                sourceHintCacheDirectory: sourceHintCacheDirectory
            )
        )
    }

    func detect() async -> Bool {
        await base.detect()
    }

    /// Own domain, not the base's: a derived listing walks only default-origin
    /// profiles, so forwarding the base's roots would declare a domain wider than
    /// what was enumerated.
    var enumerationRoots: [String] { lastListingRoots.read() }

    func listSessionLocators() async throws -> [String] {
        lastListingRoots.replace(with: [])
        let listing = try await base.listDerivedSessionLocators(source: source)
        lastListingRoots.replace(with: listing.enumerationRoots)
        return listing.locators
    }

    func listSessionLocators(modifiedSince: Date, fileManager: FileManager) async throws -> [String] {
        // Recency-filtered: a subset, so no domain (see the base's equivalent).
        lastListingRoots.replace(with: [])
        let listing = try await base.listDerivedSessionLocators(
            source: source,
            modifiedSince: modifiedSince,
            fileManager: fileManager
        )
        return listing.locators
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        switch try await base.parseSessionInfo(locator: locator) {
        case .success(let info) where info.source == source:
            return .success(info)
        case .success:
            return .failure(.unsupportedVirtualLocator)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    func scanForIndexing(locator: String) async throws -> AdapterParseResult<IndexingScan> {
        switch try await base.scanForIndexing(locator: locator) {
        case .success(let scan) where scan.info.source == source:
            return .success(scan)
        case .success:
            return .failure(.unsupportedVirtualLocator)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    func scanTailForIndexing(
        locator: String,
        from parsedOffset: Int64,
        expectedBoundaryHash: String
    ) async throws -> IndexingTailScanResult {
        switch try await base.scanTailForIndexing(
            locator: locator,
            from: parsedOffset,
            expectedBoundaryHash: expectedBoundaryHash
        ) {
        case .success(let tail) where tail.infoDelta.source == source:
            return .success(tail)
        case .success:
            return .fallback
        case .fallback:
            return .fallback
        case .failure(let failure):
            return .failure(failure)
        }
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        try await base.streamMessages(locator: locator, options: options)
    }

    func streamMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> StreamMessagesResult {
        try await base.streamMessagesWithMetadata(locator: locator, options: options)
    }

    func isAccessible(locator: String) async -> Bool {
        await base.isAccessible(locator: locator)
    }
}
