import Foundation

struct CursorAdapterTestHooks: Sendable {
    var beforeModernIdentityValidation: @Sendable () -> Void

    init(beforeModernIdentityValidation: @escaping @Sendable () -> Void = {}) {
        self.beforeModernIdentityValidation = beforeModernIdentityValidation
    }
}

final class CursorAdapter: SessionAdapter, Sendable {
    private static let modernLocatorPrefix = "cursor-modern:"

    private struct ModernLocator: Codable {
        let sessionId: String
        var storeDBPath: String?
        var transcriptPath: String?
    }

    let source: SourceName = .cursor
    private let dbPath: String
    private let cursorDataRoot: URL
    private let limits: ParserLimits
    private let accessibilityCache = Phase4SQLiteAccessibilityCache()
    private let messageCache = ParsedTranscriptCache()
    private let workspaceOwnership: CursorWorkspaceOwnershipResolver
    private let testHooks: CursorAdapterTestHooks

    init(
        dbPath: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path,
        cursorDataRoot: URL? = nil,
        limits: ParserLimits = .default,
        testHooks: CursorAdapterTestHooks = CursorAdapterTestHooks()
    ) {
        self.dbPath = dbPath
        // An injected legacy DB path must not silently fall through to the
        // process user's ~/.cursor (docs/invariants.md #6). Product factories
        // pass the matching home explicitly; isolated fixtures default closed.
        self.cursorDataRoot = cursorDataRoot ?? URL(fileURLWithPath: dbPath)
            .deletingLastPathComponent()
            .appendingPathComponent(".cursor-modern-unconfigured", isDirectory: true)
        self.limits = limits
        self.testHooks = testHooks
        let databaseURL = URL(fileURLWithPath: dbPath)
        let globalStorageURL = databaseURL.deletingLastPathComponent()
        let workspaceStorageURL = globalStorageURL.lastPathComponent == "globalStorage"
            ? globalStorageURL.deletingLastPathComponent().appendingPathComponent("workspaceStorage", isDirectory: true)
            : nil
        workspaceOwnership = CursorWorkspaceOwnershipResolver(
            workspaceStorageURL: workspaceStorageURL,
            globalDatabasePath: dbPath
        )
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.fileExists(dbPath)
            || JSONLAdapterSupport.isDirectory(cursorDataRoot.appendingPathComponent("chats", isDirectory: true))
            || JSONLAdapterSupport.isDirectory(cursorDataRoot.appendingPathComponent("projects", isDirectory: true))
    }

    func listSessionLocators() async throws -> [String] {
        var legacy: [(id: String, locator: String)] = []
        if JSONLAdapterSupport.fileExists(dbPath) {
            let database = try Phase4SQLiteDatabase(path: dbPath)
            let rows = try database.query(
                "SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%'"
            )
            legacy = rows.compactMap { row in
                guard let value = row["value"] ?? nil,
                      let data = Phase4AdapterSupport.jsonObject(from: value),
                      let composerId = JSONLAdapterSupport.string(data["composerId"]),
                      !composerId.isEmpty
                else {
                    return nil
                }
                return (composerId, "\(dbPath)?composer=\(composerId)")
            }
        }
        let modern = Self.modernLocators(under: cursorDataRoot)
        let modernIDs = Set(modern.map(\.sessionId))
        // Refresh once per discovery pass so all composers in the pass share
        // one deterministic ownership snapshot without reopening every
        // workspace database for every session.
        await workspaceOwnership.refresh()
        return legacy.filter { !modernIDs.contains($0.id) }.map(\.locator)
            + modern.compactMap(Self.encodeModernLocator)
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        if let modern = Self.decodeModernLocator(locator) {
            return await parseModernSessionInfo(locator: locator, modern: modern)
        }
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
            let firstUserText = visibleBubbles.first { $0.role == .user }?.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let userCount = visibleBubbles.filter { $0.role == .user }.count
            let assistantCount = visibleBubbles.filter { $0.role == .assistant }.count
            let firstBubbleTimestamp = Self.firstVisibleBubbleTimestamp(bubbleResult.bubbles)
            let createdAt = Phase4AdapterSupport.double(composerData["createdAt"]) ??
                firstBubbleTimestamp ??
                Phase4AdapterSupport.double(composerData["lastUpdatedAt"]) ??
                0
            let lastUpdatedAt = Phase4AdapterSupport.double(composerData["lastUpdatedAt"]) ?? createdAt
            let summary = composerData.keys.contains("latestConversationSummary")
                ? Self.conversationSummary(from: composerData)
                : firstUserText
            let displayTitle = Self.officialTitle(from: composerData)
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
                    displayTitle: displayTitle,
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

    private static func conversationSummary(from composerData: JSONLAdapterSupport.JSONObject) -> String? {
        guard let container = JSONLAdapterSupport.object(composerData["latestConversationSummary"]),
              let value = container["summary"]
        else {
            return nil
        }
        let summary = JSONLAdapterSupport.string(value) ??
            JSONLAdapterSupport.string(JSONLAdapterSupport.object(value)?["summary"])
        let trimmed = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func officialTitle(from composerData: JSONLAdapterSupport.JSONObject) -> String? {
        for key in ["title", "name"] {
            if let value = JSONLAdapterSupport.string(composerData[key])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return String(value.prefix(120))
            }
        }
        return nil
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        if let modern = Self.decodeModernLocator(locator) {
            return JSONLAdapterSupport.stream(try modernMessages(modern).messages)
        }
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
        if let modern = Self.decodeModernLocator(locator) {
            let result = try modernMessages(modern)
            return JSONLAdapterSupport.stream(
                JSONLAdapterSupport.boundedWindowWithMetadata(
                    result.messages,
                    options: options,
                    maxMessages: limits.maxMessages,
                    hasMoreMessages: result.hasMoreMessages,
                    parseFailure: result.parseFailure
                )
            )
        }
        guard let locatorParts = Self.parseVirtualLocator(locator) else {
            throw ParserFailure.unsupportedVirtualLocator
        }
        let messages = try await loadMessages(locator: locator, locatorParts: locatorParts)
        return JSONLAdapterSupport.stream(
            JSONLAdapterSupport.boundedWindowWithMetadata(
                messages,
                options: options,
                maxMessages: limits.maxMessages
            )
        )
    }

    func isAccessible(locator: String) async -> Bool {
        if let modern = Self.decodeModernLocator(locator) {
            return [modern.transcriptPath, modern.storeDBPath]
                .compactMap { $0 }
                .contains(where: JSONLAdapterSupport.fileExists)
        }
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

    private func parseModernSessionInfo(
        locator: String,
        modern: ModernLocator
    ) async -> AdapterParseResult<NormalizedSessionInfo> {
        do {
            let result = try modernMessages(modern)
            let messages = result.messages
            if let failure = result.parseFailure {
                guard failure == .fileModifiedDuringParse, !messages.isEmpty else {
                    return .failure(failure)
                }
            }
            if result.hasMoreMessages { return .failure(.messageLimitExceeded) }
            guard !messages.isEmpty else { return .failure(.noVisibleMessages) }
            guard messages.count <= limits.maxMessages else {
                return .failure(.messageLimitExceeded)
            }
            let metadata = try modernMetadata(modern)
            let firstUser = messages.first { $0.role == .user }?.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let createdAt = Phase4AdapterSupport.double(metadata["createdAtMs"])
                ?? Phase4AdapterSupport.double(metadata["createdAt"])
                ?? Self.modificationMilliseconds(for: modern.transcriptPath ?? modern.storeDBPath)
                ?? 0
            let updatedAt = Self.modificationMilliseconds(for: modern.transcriptPath ?? modern.storeDBPath)
                ?? createdAt
            let officialName = Self.officialTitle(from: metadata)
            let cwd = JSONLAdapterSupport.string(metadata["cwd"])?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let userCount = messages.filter { $0.role == .user }.count
            let assistantCount = messages.filter { $0.role == .assistant }.count
            let sizeBytes = [modern.storeDBPath, modern.transcriptPath]
                .compactMap { $0 }
                .reduce(Int64(0)) { $0 + JSONLAdapterSupport.fileSize(locator: $1) }
            return .success(
                NormalizedSessionInfo(
                    id: modern.sessionId,
                    source: .cursor,
                    startTime: Phase4AdapterSupport.isoFromMilliseconds(createdAt),
                    endTime: updatedAt != createdAt
                        ? Phase4AdapterSupport.isoFromMilliseconds(updatedAt)
                        : nil,
                    cwd: cwd,
                    project: cwd.isEmpty ? nil : URL(fileURLWithPath: cwd).lastPathComponent,
                    model: nil,
                    messageCount: messages.count,
                    userMessageCount: userCount,
                    assistantMessageCount: assistantCount,
                    toolMessageCount: 0,
                    systemMessageCount: 0,
                    summary: (metadata.keys.contains("latestConversationSummary")
                        ? Self.conversationSummary(from: metadata)
                        : firstUser).map { String($0.prefix(200)) },
                    displayTitle: officialName,
                    filePath: locator,
                    sizeBytes: sizeBytes,
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

    private struct ModernMessageReadResult {
        let messages: [NormalizedMessage]
        let parseFailure: ParserFailure?
        let hasMoreMessages: Bool
    }

    private func modernMessages(_ modern: ModernLocator) throws -> ModernMessageReadResult {
        if let transcriptPath = modern.transcriptPath {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(
                locator: transcriptPath,
                limits: limits,
                reportFailures: true,
                countsTowardMessageLimit: { Self.modernMessage(from: $0) != nil },
                beforeIdentityValidation: testHooks.beforeModernIdentityValidation
            )
            let messages = objects.compactMap(Self.modernMessage)
            if messages.isEmpty, let failure { throw failure }
            return ModernMessageReadResult(
                messages: messages,
                parseFailure: failure,
                hasMoreMessages: failure == .messageLimitExceeded
            )
        }
        guard let storeDBPath = modern.storeDBPath else { throw ParserFailure.fileMissing }
        _ = try JSONLAdapterSupport.prepareFile(locator: storeDBPath, limits: limits)
        let database = try Phase4SQLiteDatabase(path: storeDBPath)
        let rows = try database.query("""
            SELECT CAST(data AS TEXT) AS data
            FROM blobs
            WHERE json_valid(data)
              AND json_extract(data, '$.role') IN ('user', 'assistant')
            ORDER BY rowid ASC
            LIMIT \(limits.maxMessages + 1)
            """)
        let messages = rows.compactMap { row in
            (row["data"] ?? nil)
                .flatMap(Phase4AdapterSupport.jsonObject(from:))
                .flatMap(Self.modernMessage)
        }
        return ModernMessageReadResult(
            messages: Array(messages.prefix(limits.maxMessages)),
            parseFailure: nil,
            hasMoreMessages: messages.count > limits.maxMessages
        )
    }

    private func modernMetadata(_ modern: ModernLocator) throws -> JSONLAdapterSupport.JSONObject {
        var metadata: JSONLAdapterSupport.JSONObject = [:]
        if let storeDBPath = modern.storeDBPath {
            let database = try Phase4SQLiteDatabase(path: storeDBPath)
            if let encoded = try database.query(
                "SELECT value FROM meta WHERE key = '0' LIMIT 1"
            ).first?["value"] ?? nil {
                let data = Self.dataFromHex(encoded) ?? Data(encoded.utf8)
                if let stored = try? JSONSerialization.jsonObject(with: data)
                    as? JSONLAdapterSupport.JSONObject {
                    metadata.merge(stored) { _, storedValue in storedValue }
                }
            }

            let metaPath = URL(fileURLWithPath: storeDBPath)
                .deletingLastPathComponent()
                .appendingPathComponent("meta.json")
            if let text = try? JSONLAdapterSupport.readString(
                locator: metaPath.path,
                limits: limits
            ), let live = Phase4AdapterSupport.jsonObject(from: text) {
                // The live per-chat metadata is authoritative over the older
                // store.db snapshot, including an explicitly empty digest.
                metadata.merge(live) { _, liveValue in liveValue }
            }
        }
        return metadata
    }

    private static func modernMessage(from object: JSONLAdapterSupport.JSONObject) -> NormalizedMessage? {
        guard let rawRole = JSONLAdapterSupport.string(object["role"])?.lowercased() else { return nil }
        let role: NormalizedMessageRole
        switch rawRole {
        case "user": role = .user
        case "assistant": role = .assistant
        default: return nil
        }
        let payload = JSONLAdapterSupport.object(object["message"]) ?? object
        guard let content = modernContent(payload["content"]) else { return nil }
        return NormalizedMessage(role: role, content: content, timestamp: nil)
    }

    private static func modernContent(_ value: Any?) -> String? {
        if let text = JSONLAdapterSupport.string(value)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        guard let parts = JSONLAdapterSupport.array(value) else { return nil }
        let text = parts.compactMap { part -> String? in
            guard let object = JSONLAdapterSupport.object(part),
                  JSONLAdapterSupport.string(object["type"]) == "text"
            else { return nil }
            return JSONLAdapterSupport.string(object["text"])
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func modernLocators(under cursorRoot: URL) -> [ModernLocator] {
        var byID: [String: ModernLocator] = [:]
        let chatsRoot = cursorRoot.appendingPathComponent("chats", isDirectory: true)
        for workspace in JSONLAdapterSupport.directChildren(of: chatsRoot)
            where JSONLAdapterSupport.isDirectory(workspace)
        {
            for session in JSONLAdapterSupport.directChildren(of: workspace)
                where JSONLAdapterSupport.isDirectory(session)
            {
                let store = session.appendingPathComponent("store.db")
                guard JSONLAdapterSupport.fileExists(store.path) else { continue }
                let id = session.lastPathComponent
                byID[id] = ModernLocator(
                    sessionId: id,
                    storeDBPath: store.path,
                    transcriptPath: byID[id]?.transcriptPath
                )
            }
        }
        let projectsRoot = cursorRoot.appendingPathComponent("projects", isDirectory: true)
        for project in JSONLAdapterSupport.directChildren(of: projectsRoot)
            where JSONLAdapterSupport.isDirectory(project)
        {
            let transcripts = project.appendingPathComponent("agent-transcripts", isDirectory: true)
            for session in JSONLAdapterSupport.directChildren(of: transcripts)
                where JSONLAdapterSupport.isDirectory(session)
            {
                let id = session.lastPathComponent
                let transcript = session.appendingPathComponent("\(id).jsonl")
                guard JSONLAdapterSupport.fileExists(transcript.path) else { continue }
                byID[id] = ModernLocator(
                    sessionId: id,
                    storeDBPath: byID[id]?.storeDBPath,
                    transcriptPath: transcript.path
                )
            }
        }
        return byID.values.sorted { $0.sessionId < $1.sessionId }
    }

    private static func encodeModernLocator(_ locator: ModernLocator) -> String? {
        guard let data = try? JSONEncoder().encode(locator) else { return nil }
        return modernLocatorPrefix + data.base64EncodedString()
    }

    private static func decodeModernLocator(_ locator: String) -> ModernLocator? {
        guard locator.hasPrefix(modernLocatorPrefix),
              let data = Data(base64Encoded: String(locator.dropFirst(modernLocatorPrefix.count)))
        else { return nil }
        return try? JSONDecoder().decode(ModernLocator.self, from: data)
    }

    private static func dataFromHex(_ string: String) -> Data? {
        guard string.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        data.reserveCapacity(string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func modificationMilliseconds(for path: String?) -> Double? {
        guard let path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attributes[.modificationDate] as? Date
        else { return nil }
        return date.timeIntervalSince1970 * 1_000
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
    private let globalDatabasePath: String
    private var cwdByComposerId: [String: String]?

    init(workspaceStorageURL: URL?, globalDatabasePath: String) {
        self.workspaceStorageURL = workspaceStorageURL
        self.globalDatabasePath = globalDatabasePath
    }

    func refresh() {
        cwdByComposerId = Self.loadOwnership(
            from: workspaceStorageURL,
            globalDatabasePath: globalDatabasePath
        )
    }

    func cwd(for composerId: String) -> String {
        if cwdByComposerId == nil {
            refresh()
        }
        return cwdByComposerId?[composerId] ?? ""
    }

    private static func loadOwnership(
        from workspaceStorageURL: URL?,
        globalDatabasePath: String
    ) -> [String: String] {
        guard let workspaceStorageURL else { return [:] }

        var pathsByComposerId: [String: Set<String>] = [:]
        var cwdByWorkspaceIdentifier: [String: String] = [:]
        for workspaceURL in JSONLAdapterSupport.directChildren(of: workspaceStorageURL)
            where JSONLAdapterSupport.isDirectory(workspaceURL)
        {
            guard let cwd = singleFolderPath(from: workspaceURL) else { continue }
            cwdByWorkspaceIdentifier[workspaceURL.lastPathComponent] = cwd
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

        if let database = try? Phase4SQLiteDatabase(path: globalDatabasePath),
           let row = try? database.query(
               "SELECT value FROM ItemTable WHERE key = ?",
               bindings: ["composer.composerHeaders"]
           ).first,
           let value = row["value"] ?? nil,
           let index = Phase4AdapterSupport.jsonObject(from: value),
           let headers = JSONLAdapterSupport.array(index["allComposers"])
        {
            for header in headers.compactMap({ JSONLAdapterSupport.object($0) }) {
                guard let composerId = JSONLAdapterSupport.string(header["composerId"]),
                      !composerId.isEmpty,
                      let workspaceIdentifier = JSONLAdapterSupport.object(header["workspaceIdentifier"]),
                      let workspaceID = JSONLAdapterSupport.string(workspaceIdentifier["id"]),
                      let cwd = cwdByWorkspaceIdentifier[workspaceID]
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
