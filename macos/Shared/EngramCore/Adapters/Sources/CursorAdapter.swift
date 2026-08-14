import Foundation

final class CursorAdapter: SessionAdapter, Sendable {
    let source: SourceName = .cursor
    private let dbPath: String
    private let limits: ParserLimits
    private let accessibilityCache = Phase4SQLiteAccessibilityCache()
    private let messageCache = ParsedTranscriptCache()
    private let workspaceOwnership: CursorWorkspaceOwnershipResolver

    init(
        dbPath: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path,
        limits: ParserLimits = .default
    ) {
        self.dbPath = dbPath
        self.limits = limits
        let databaseURL = URL(fileURLWithPath: dbPath)
        let globalStorageURL = databaseURL.deletingLastPathComponent()
        let workspaceStorageURL = globalStorageURL.lastPathComponent == "globalStorage"
            ? globalStorageURL.deletingLastPathComponent().appendingPathComponent("workspaceStorage", isDirectory: true)
            : nil
        workspaceOwnership = CursorWorkspaceOwnershipResolver(workspaceStorageURL: workspaceStorageURL)
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.fileExists(dbPath)
    }

    func listSessionLocators() async throws -> [String] {
        guard JSONLAdapterSupport.fileExists(dbPath) else { return [] }
        let database = try Phase4SQLiteDatabase(path: dbPath)
        let rows = try database.query(
            "SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%'"
        )
        let locators: [String] = rows.compactMap { row in
            guard let value = row["value"] ?? nil,
                  let data = Phase4AdapterSupport.jsonObject(from: value),
                  let composerId = JSONLAdapterSupport.string(data["composerId"]),
                  !composerId.isEmpty
            else {
                return nil
            }
            return "\(dbPath)?composer=\(composerId)"
        }
        // Refresh once per discovery pass so all composers in the pass share
        // one deterministic ownership snapshot without reopening every
        // workspace database for every session.
        await workspaceOwnership.refresh()
        return locators
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        guard let locatorParts = Self.parseVirtualLocator(locator) else {
            return .failure(.unsupportedVirtualLocator)
        }

        do {
            let database = try Phase4SQLiteDatabase(path: locatorParts.dbPath)
            guard let composerRow = try database.query(
                "SELECT value FROM cursorDiskKV WHERE key = ?",
                bindings: ["composerData:\(locatorParts.composerId)"]
            ).first,
                let composerValue = composerRow["value"] ?? nil,
                let composerData = Phase4AdapterSupport.jsonObject(from: composerValue)
            else {
                return .failure(.malformedJSON)
            }

            let bubbleResult = try Self.bubbles(
                database: database,
                composerData: composerData,
                composerId: locatorParts.composerId
            )
            let visibleBubbles = bubbleResult.bubbles.compactMap(Self.visibleBubble)
            let userCount = visibleBubbles.filter { $0.role == .user }.count
            let assistantCount = visibleBubbles.filter { $0.role == .assistant }.count
            let firstBubbleTimestamp = Self.firstVisibleBubbleTimestamp(bubbleResult.bubbles)
            let createdAt = Phase4AdapterSupport.double(composerData["createdAt"]) ??
                firstBubbleTimestamp ??
                Phase4AdapterSupport.double(composerData["lastUpdatedAt"]) ??
                0
            let lastUpdatedAt = Phase4AdapterSupport.double(composerData["lastUpdatedAt"]) ?? createdAt
            let summary = JSONLAdapterSupport.string(
                JSONLAdapterSupport.object(composerData["latestConversationSummary"])?["summary"]
            )
            let sessionId = JSONLAdapterSupport.string(composerData["composerId"]) ?? locatorParts.composerId
            let cwd = await workspaceOwnership.cwd(for: sessionId)
            let project = cwd.isEmpty ? nil : URL(fileURLWithPath: cwd).lastPathComponent
            // Per-session size = this composer's raw JSON payload plus the raw
            // JSON of any separately-stored bubble rows. state.vscdb is shared
            // by every Cursor session, so measuring the whole file (the old
            // behavior) attributed the entire DB size to each session. This
            // matches the TS cursor adapter byte-for-byte for parity.
            let perSessionBytes = Int64(composerValue.utf8.count) + bubbleResult.rawBubbleBytes
            // R184-3: composer metadata with no visible user/assistant bubbles
            // must not become a zero-count browsable session. Terminal, same as
            // Claude/Qwen.
            guard userCount + assistantCount > 0 else {
                return .failure(.noVisibleMessages)
            }
            if userCount + assistantCount > limits.maxMessages {
                return .failure(.messageLimitExceeded)
            }

            return .success(
                NormalizedSessionInfo(
                    id: sessionId,
                    source: .cursor,
                    startTime: Phase4AdapterSupport.isoFromMilliseconds(createdAt),
                    endTime: lastUpdatedAt != createdAt ? Phase4AdapterSupport.isoFromMilliseconds(lastUpdatedAt) : nil,
                    cwd: cwd,
                    project: project,
                    model: nil,
                    messageCount: userCount + assistantCount,
                    userMessageCount: userCount,
                    assistantMessageCount: assistantCount,
                    toolMessageCount: 0,
                    systemMessageCount: 0,
                    summary: summary.map { String($0.prefix(200)) },
                    filePath: locator,
                    sizeBytes: perSessionBytes,
                    indexedAt: nil,
                    agentRole: nil,
                    originator: nil,
                    origin: nil,
                    summaryMessageCount: nil,
                    tier: nil,
                    qualityScore: nil,
                    parentSessionId: nil,
                    suggestedParentId: nil
                )
            )
        } catch let failure as ParserFailure {
            return .failure(failure)
        } catch {
            return .failure(.sqliteUnreadable)
        }
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        guard let locatorParts = Self.parseVirtualLocator(locator) else {
            throw ParserFailure.unsupportedVirtualLocator
        }

        let messages = try await loadMessages(locator: locator, locatorParts: locatorParts)
        return JSONLAdapterSupport.stream(JSONLAdapterSupport.applyWindow(messages, options: options))
    }

    func streamMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> StreamMessagesResult {
        guard let locatorParts = Self.parseVirtualLocator(locator) else {
            throw ParserFailure.unsupportedVirtualLocator
        }
        let messages = try await loadMessages(locator: locator, locatorParts: locatorParts)
        let truncatedAt = options.limit == nil && messages.count > limits.maxMessages
            ? limits.maxMessages
            : nil
        let bounded = truncatedAt == nil
            ? JSONLAdapterSupport.applyWindow(messages, options: options)
            : Array(messages.prefix(limits.maxMessages))
        return StreamMessagesResult(
            messages: JSONLAdapterSupport.stream(bounded),
            totalKnownComplete: truncatedAt == nil,
            truncatedAt: truncatedAt
        )
    }

    func isAccessible(locator: String) async -> Bool {
        guard let locatorParts = Self.parseVirtualLocator(locator) else {
            return false
        }
        return await accessibilityCache.contains(
            path: locatorParts.dbPath,
            sql:
            "SELECT 1 FROM cursorDiskKV WHERE key = ? LIMIT 1",
            bindings: ["composerData:\(locatorParts.composerId)"]
        )
    }

    private func loadMessages(
        locator: String,
        locatorParts: (dbPath: String, composerId: String)
    ) async throws -> [NormalizedMessage] {
        let signature = ParsedTranscriptCache.Signature.forFile(locatorParts.dbPath)
        if let cached = await messageCache.cached(locator: locator, signature: signature) {
            return cached
        }
        do {
            let database = try Phase4SQLiteDatabase(path: locatorParts.dbPath)
            var composerData: Phase4AdapterSupport.JSONObject = [:]
            if let composerRow = try database.query(
                "SELECT value FROM cursorDiskKV WHERE key = ?",
                bindings: ["composerData:\(locatorParts.composerId)"]
            ).first,
                let composerValue = composerRow["value"] ?? nil,
                let parsed = Phase4AdapterSupport.jsonObject(from: composerValue)
            {
                composerData = parsed
            }
            let bubbleResult = try Self.bubbles(
                database: database,
                composerData: composerData,
                composerId: locatorParts.composerId
            )
            let messages = bubbleResult.bubbles.compactMap { bubble -> NormalizedMessage? in
                guard let visible = Self.visibleBubble(bubble) else { return nil }
                let timestamp = Phase4AdapterSupport.double(
                    JSONLAdapterSupport.object(bubble["timingInfo"])?["clientStartTime"]
                )
                .map { Phase4AdapterSupport.isoFromMilliseconds($0) }
                return NormalizedMessage(
                    role: visible.role,
                    content: visible.content,
                    timestamp: timestamp,
                    toolCalls: nil,
                    usage: visible.role == .assistant
                        ? Self.usage(from: JSONLAdapterSupport.object(bubble["tokenCount"]))
                        : nil
                )
            }
            await messageCache.store(locator: locator, signature: signature, messages: messages)
            return messages
        } catch let failure as ParserFailure {
            throw failure
        } catch {
            throw ParserFailure.sqliteUnreadable
        }
    }

    private static func parseVirtualLocator(_ locator: String) -> (dbPath: String, composerId: String)? {
        guard let range = locator.range(of: "?composer=") else { return nil }
        return (
            dbPath: String(locator[..<range.lowerBound]),
            composerId: String(locator[range.upperBound...])
        )
    }

    private struct BubbleLoadResult {
        let bubbles: [Phase4AdapterSupport.JSONObject]
        /// Raw UTF-8 byte total of separately-stored bubble row JSON values
        /// (0 when the conversation is embedded in composerData). Mirrors the
        /// TS cursor adapter so per-session sizeBytes stays in parity.
        let rawBubbleBytes: Int64
    }

    private static func bubbles(
        database: Phase4SQLiteDatabase,
        composerData: Phase4AdapterSupport.JSONObject,
        composerId: String
    ) throws -> BubbleLoadResult {
        if let conversation = JSONLAdapterSupport.array(composerData["conversation"]),
           !conversation.isEmpty
        {
            return BubbleLoadResult(
                bubbles: conversation.compactMap { JSONLAdapterSupport.object($0) },
                rawBubbleBytes: 0
            )
        }

        let rows = try database.query(
            "SELECT value FROM cursorDiskKV WHERE key LIKE ? ORDER BY rowid ASC",
            bindings: ["bubbleId:\(composerId):%"]
        )
        var bubbles: [Phase4AdapterSupport.JSONObject] = []
        var rawBytes: Int64 = 0
        for row in rows {
            guard let value = row["value"] ?? nil else { continue }
            rawBytes += Int64(value.utf8.count)
            if let object = Phase4AdapterSupport.jsonObject(from: value) {
                bubbles.append(object)
            }
        }
        return BubbleLoadResult(bubbles: bubbles, rawBubbleBytes: rawBytes)
    }

    private static func visibleBubble(
        _ bubble: Phase4AdapterSupport.JSONObject
    ) -> (role: NormalizedMessageRole, content: String)? {
        let type = (bubble["type"] as? NSNumber)?.intValue
        let role: NormalizedMessageRole
        if type == 1 {
            role = .user
        } else if type == 2 {
            role = .assistant
        } else {
            return nil
        }

        // Prefer the first non-empty-after-trim candidate. Empty/whitespace `text`
        // must not shadow a restored `rawText` payload (nil-coalescing would).
        let content = Self.firstNonEmptyContent(
            JSONLAdapterSupport.string(bubble["text"]),
            JSONLAdapterSupport.string(bubble["rawText"])
        )
        guard let content else { return nil }
        return (role, content)
    }

    private static func firstNonEmptyContent(_ candidates: String?...) -> String? {
        for candidate in candidates {
            guard let candidate else { continue }
            if !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
        }
        return nil
    }

    private static func firstVisibleBubbleTimestamp(_ bubbles: [Phase4AdapterSupport.JSONObject]) -> Double? {
        for bubble in bubbles where visibleBubble(bubble) != nil {
            if let timestamp = Phase4AdapterSupport.double(
                JSONLAdapterSupport.object(bubble["timingInfo"])?["clientStartTime"]
            ) {
                return timestamp
            }
        }
        return nil
    }

    private static func usage(from tokenCount: Phase4AdapterSupport.JSONObject?) -> TokenUsage? {
        guard let tokenCount else { return nil }
        let usage = TokenUsage(
            inputTokens: int(tokenCount["inputTokens"]),
            outputTokens: int(tokenCount["outputTokens"]),
            cacheReadTokens: 0,
            cacheCreationTokens: 0
        )
        guard usage.inputTokens > 0 || usage.outputTokens > 0 else { return nil }
        return usage
    }

    private static func int(_ value: Any?) -> Int {
        Int(Phase4AdapterSupport.int64(value) ?? 0)
    }
}

/// Resolves Cursor composer ownership from the per-workspace pointer index.
/// Context file/folder selections are deliberately excluded: they describe
/// attached prompt context, not the workspace that owns the composer.
private actor CursorWorkspaceOwnershipResolver {
    private let workspaceStorageURL: URL?
    private var cwdByComposerId: [String: String]?

    init(workspaceStorageURL: URL?) {
        self.workspaceStorageURL = workspaceStorageURL
    }

    func refresh() {
        cwdByComposerId = Self.loadOwnership(from: workspaceStorageURL)
    }

    func cwd(for composerId: String) -> String {
        if cwdByComposerId == nil {
            refresh()
        }
        return cwdByComposerId?[composerId] ?? ""
    }

    private static func loadOwnership(from workspaceStorageURL: URL?) -> [String: String] {
        guard let workspaceStorageURL else { return [:] }

        var pathsByComposerId: [String: Set<String>] = [:]
        for workspaceURL in JSONLAdapterSupport.directChildren(of: workspaceStorageURL)
            where JSONLAdapterSupport.isDirectory(workspaceURL)
        {
            guard let cwd = singleFolderPath(from: workspaceURL) else { continue }
            let databaseURL = workspaceURL.appendingPathComponent("state.vscdb")
            guard JSONLAdapterSupport.fileExists(databaseURL.path),
                  let database = try? Phase4SQLiteDatabase(path: databaseURL.path),
                  let row = try? database.query(
                      "SELECT value FROM ItemTable WHERE key = ?",
                      bindings: ["composer.composerData"]
                  ).first,
                  let value = row["value"] ?? nil,
                  let index = Phase4AdapterSupport.jsonObject(from: value),
                  let composers = JSONLAdapterSupport.array(index["allComposers"])
            else {
                continue
            }

            for composer in composers.compactMap({ JSONLAdapterSupport.object($0) }) {
                guard let composerId = JSONLAdapterSupport.string(composer["composerId"]),
                      !composerId.isEmpty
                else {
                    continue
                }
                pathsByComposerId[composerId, default: []].insert(cwd)
            }
        }

        return pathsByComposerId.compactMapValues { paths in
            paths.count == 1 ? paths.first : nil
        }
    }

    private static func singleFolderPath(from workspaceURL: URL) -> String? {
        let metadataURL = workspaceURL.appendingPathComponent("workspace.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONSerialization.jsonObject(with: data) as? Phase4AdapterSupport.JSONObject,
              // A configuration points at a potentially multi-root
              // .code-workspace. It is intentionally not assigned a primary.
              metadata["configuration"] == nil,
              let folderURI = JSONLAdapterSupport.string(metadata["folder"]),
              let url = URL(string: folderURI),
              url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost"
        else {
            return nil
        }

        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/"), path != "/" else { return nil }
        return path
    }
}
