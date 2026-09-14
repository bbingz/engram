import Darwin
import Foundation

struct CursorAdapterTestHooks: Sendable {
    var beforeModernIdentityValidation: @Sendable () -> Void

    init(beforeModernIdentityValidation: @escaping @Sendable () -> Void = {}) {
        self.beforeModernIdentityValidation = beforeModernIdentityValidation
    }
}

final class CursorAdapter: SessionAdapter, ModificationFilteredSessionAdapter, Sendable {
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
    private let capturedPrimaryMtimeNs: Int64?
    private let capturedWALAbsent: Bool
    private let capturedLegacySession: ArchiveCursorLegacySession?

    init(
        dbPath: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path,
        cursorDataRoot: URL? = nil,
        limits: ParserLimits = .default,
        testHooks: CursorAdapterTestHooks = CursorAdapterTestHooks(),
        capturedPrimaryMtimeNs: Int64? = nil,
        capturedWALAbsent: Bool = false,
        capturedLegacySession: ArchiveCursorLegacySession? = nil
    ) {
        self.dbPath = capturedLegacySession == nil ? dbPath : ""
        self.limits = limits
        self.testHooks = testHooks
        self.capturedPrimaryMtimeNs = capturedPrimaryMtimeNs
        self.capturedWALAbsent = capturedWALAbsent
        self.capturedLegacySession = capturedLegacySession
        if capturedLegacySession != nil {
            // Even URL directory inference must not probe the archived path.
            self.cursorDataRoot = URL(fileURLWithPath: "/", isDirectory: true)
            workspaceOwnership = CursorWorkspaceOwnershipResolver(workspaceStorageURL: nil, globalDatabasePath: "")
        } else {
            // Injected legacy DBs do not discover the process user's ~/.cursor.
            // Product factories pass the matching home explicitly.
            self.cursorDataRoot = cursorDataRoot ?? URL(fileURLWithPath: dbPath)
                .deletingLastPathComponent()
                .appendingPathComponent(".cursor-modern-unconfigured", isDirectory: true)
            let globalStorageURL = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
            let workspaceStorageURL = globalStorageURL.lastPathComponent == "globalStorage"
                ? globalStorageURL.deletingLastPathComponent().appendingPathComponent("workspaceStorage", isDirectory: true)
                : nil
            workspaceOwnership = CursorWorkspaceOwnershipResolver(
                workspaceStorageURL: workspaceStorageURL, globalDatabasePath: dbPath)
        }
    }

    static func scanCapturedLegacySession(
        _ session: ArchiveCursorLegacySession, logicalLocator: String,
        limits: ParserLimits = .default
    ) async throws -> AdapterParseResult<CapturedSourceScan> {
        try Task.checkCancellation()
        guard logicalLocator.utf8.elementsEqual(session.logicalLocator.utf8) else {
            return .failure(.unsupportedVirtualLocator)
        }
        guard session.rawPayloadByteCount <= limits.maxFileBytes else {
            return .failure(.fileTooLarge)
        }
        let adapter = CursorAdapter(dbPath: session.logicalDatabaseLocator, limits: limits,
            capturedLegacySession: session)
        switch try await adapter.scanForIndexing(locator: logicalLocator) {
        case .failure(let failure): return .failure(failure)
        case .success(let scan):
            guard scan.info.id.utf8.elementsEqual(session.composerID.utf8),
                  scan.info.cwd.utf8.elementsEqual(session.cwd.utf8) else { return .failure(.malformedJSON) }
            return .success(CapturedSourceScan(scan: scan, rawSourceSessionID: session.composerID))
        }
    }

    static func scanCapturedLegacySource(
        physicalLocator: String, stagingRoot: String, logicalLocator: String,
        context: ArchiveCursorLegacyContext, generation: ArchiveSourceGeneration
    ) async throws -> AdapterParseResult<CapturedSourceScan> {
        try Task.checkCancellation()
        guard stagingRoot.hasPrefix("/"),
              ArchiveReplayLayout.isNormalizedRelativePath(String(stagingRoot.dropFirst())),
              physicalLocator.utf8.elementsEqual((stagingRoot + "/session.cursor-legacy.json").utf8),
              logicalLocator.utf8.elementsEqual(context.logicalLocator.utf8) else {
            return .failure(.unsupportedVirtualLocator)
        }
        // HQ seals and verifies this private file before/after the call. Bound
        // the actual read too; direct callers cannot cause an unbounded read.
        let descriptor = Darwin.open(physicalLocator, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return .failure(.sqliteUnreadable) }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            return .failure(.sqliteUnreadable)
        }
        guard info.st_size <= ArchiveCursorLegacySession.maximumEncodedByteCount else { return .failure(.fileTooLarge) }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                return .failure(.sqliteUnreadable)
            }
            if count == 0 { break }
            guard Int64(bytes.count) + Int64(count) <= ArchiveCursorLegacySession.maximumEncodedByteCount else {
                return .failure(.fileTooLarge)
            }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        let body: ArchiveCursorLegacySession
        do {
            body = try ArchiveCursorLegacySession.decodeCanonical(bytes)
            guard body.databaseGeneration == generation, try ArchiveCursorLegacyContext(session: body) == context else {
                return .failure(.malformedJSON)
            }
        } catch { return .failure(.malformedJSON) }
        return try await scanCapturedLegacySession(body, logicalLocator: logicalLocator)
    }

    private func legacyDatabase(locator: String, path: String) throws -> Phase4SQLiteDatabase {
        if let capturedLegacySession {
            guard locator.utf8.elementsEqual(capturedLegacySession.logicalLocator.utf8) else {
                throw ParserFailure.unsupportedVirtualLocator
            }
            return try Phase4SQLiteDatabase(cursorLegacySession: capturedLegacySession)
        }
        return try Phase4SQLiteDatabase(path: path)
    }

    static func scanCapturedSource(
        physicalLocator: String, stagingRoot: String, logicalLocator: String,
        replayLayout: ArchiveReplayLayout, capturedModificationNanoseconds: Int64?
    ) async throws -> AdapterParseResult<CapturedSourceScan> {
        try Task.checkCancellation()
        guard let nativeID = ArchiveSourceDescriptor.cursorModernSessionID(replayLayout, locator: logicalLocator),
              let entries = replayLayout.files, let primary = replayLayout.entrypointRelativePath,
              let primaryEntry = entries.first(where: { $0.relativePath.utf8.elementsEqual(primary.utf8) }) else {
            return .failure(.malformedJSON)
        }
        let root = URL(fileURLWithPath: stagingRoot, isDirectory: true)
        guard physicalLocator.utf8.elementsEqual(root.appendingPathComponent(primary).path.utf8),
              capturedModificationNanoseconds == nil || capturedModificationNanoseconds == primaryEntry.generation.mtimeNs else {
            return .failure(.malformedJSON)
        }
        // Only declared members can supply metadata. An omitted WAL/meta file
        // must not be borrowed from the physical staging tree.
        for relative in replayLayout.absentRelativePaths ?? [] {
            var info = stat()
            guard Darwin.lstat(root.appendingPathComponent(relative).path, &info) != 0, errno == ENOENT else {
                return .failure(.malformedJSON)
            }
        }
        let modern = ModernLocator(sessionId: nativeID,
            storeDBPath: entries.first(where: { $0.relativePath.hasSuffix("/store.db") })
                .map { root.appendingPathComponent($0.relativePath).path },
            transcriptPath: entries.first(where: { $0.relativePath.hasSuffix(".jsonl") })
                .map { root.appendingPathComponent($0.relativePath).path })
        // Construct exactly the captured locator; no home or legacy discovery.
        let adapter = CursorAdapter(dbPath: root.appendingPathComponent(".no-legacy-db").path,
            cursorDataRoot: root, capturedPrimaryMtimeNs: primaryEntry.generation.mtimeNs,
            capturedWALAbsent: !entries.contains(where: { $0.relativePath.hasSuffix("/store.db-wal") }))
        guard let confined = adapter.confinedModernLocator(modern),
              let locator = encodeModernLocator(confined) else { return .failure(.malformedJSON) }
        switch try await adapter.scanForIndexing(locator: locator) {
        case .failure(let failure): return .failure(failure)
        case .success(var scan):
            if let failure = scan.parseFailure { return .failure(failure) }
            guard scan.info.id.utf8.elementsEqual(nativeID.utf8) else { return .failure(.malformedJSON) }
            scan.info.filePath = logicalLocator
            return .success(CapturedSourceScan(scan: scan, rawSourceSessionID: nativeID))
        }
    }

    func detect() async -> Bool {
        if capturedLegacySession != nil { return true }
        return JSONLAdapterSupport.fileExists(dbPath)
            || JSONLAdapterSupport.isDirectory(cursorDataRoot.appendingPathComponent("chats", isDirectory: true))
            || JSONLAdapterSupport.isDirectory(cursorDataRoot.appendingPathComponent("projects", isDirectory: true))
    }

    func listSessionLocators() async throws -> [String] {
        if let capturedLegacySession { return [capturedLegacySession.logicalLocator] }
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
        let modern = Self.modernLocators(under: cursorDataRoot).filter {
            confinedModernLocator($0) != nil
        }
        let modernIDs = Set(modern.map(\.sessionId))
        // Refresh once per discovery pass so all composers in the pass share
        // one deterministic ownership snapshot without reopening every
        // workspace database for every session.
        await workspaceOwnership.refresh()
        return legacy.filter { !modernIDs.contains($0.id) }.map(\.locator)
            + modern.compactMap(Self.encodeModernLocator)
    }

    func listSessionLocators(
        modifiedSince: Date,
        fileManager: FileManager
    ) async throws -> [String] {
        if let capturedLegacySession { return [capturedLegacySession.logicalLocator] }
        return try await listSessionLocators().filter { locator in
            guard let modern = decodeModernLocator(locator) else {
                guard let legacy = Self.parseVirtualLocator(locator),
                      let modifiedAt = try? fileManager.attributesOfItem(
                          atPath: legacy.dbPath
                      )[.modificationDate] as? Date else {
                    return false
                }
                return modifiedAt >= modifiedSince
            }
            return Self.compositeModificationDate(modern, fileManager: fileManager)
                .map { $0 >= modifiedSince } ?? false
        }
    }

    func indexingInputIdentity(locator: String) -> IndexingInputIdentity? {
        if capturedLegacySession != nil { return nil }
        guard let modern = decodeModernLocator(locator) else { return nil }
        return Self.compositeInputIdentity(modern)
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        if let capturedLegacySession, !locator.utf8.elementsEqual(capturedLegacySession.logicalLocator.utf8) {
            return .failure(.unsupportedVirtualLocator)
        }
        if let modern = decodeModernLocator(locator) {
            return await parseModernSessionInfo(locator: locator, modern: modern)
        }
        guard let locatorParts = Self.parseVirtualLocator(locator) else {
            return .failure(.unsupportedVirtualLocator)
        }

        do {
            let database = try legacyDatabase(locator: locator, path: locatorParts.dbPath)
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
                composerId: locatorParts.composerId,
                maxMessages: limits.maxMessages
            )
            if bubbleResult.hasMoreMessages { return .failure(.messageLimitExceeded) }
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
            let cwd: String
            if let capturedLegacySession { cwd = capturedLegacySession.cwd }
            else { cwd = await workspaceOwnership.cwd(for: sessionId) }
            let project = capturedLegacySession != nil
                ? cwd.split(separator: "/").last.map(String.init)
                : (cwd.isEmpty ? nil : URL(fileURLWithPath: cwd).lastPathComponent)
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
        let result = try await streamMessagesWithMetadata(locator: locator, options: options)
        if options.limit == nil, result.truncatedAt != nil {
            throw ParserFailure.messageLimitExceeded
        }
        return result.messages
    }

    func streamMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> StreamMessagesResult {
        if let capturedLegacySession, !locator.utf8.elementsEqual(capturedLegacySession.logicalLocator.utf8) {
            throw ParserFailure.unsupportedVirtualLocator
        }
        if let modern = decodeModernLocator(locator) {
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
        let load = try await loadMessages(locator: locator, locatorParts: locatorParts)
        return JSONLAdapterSupport.stream(
            JSONLAdapterSupport.boundedWindowWithMetadata(
                load.messages,
                options: options,
                maxMessages: limits.maxMessages,
                hasMoreMessages: load.hasMoreMessages
            )
        )
    }

    func isAccessible(locator: String) async -> Bool {
        if let capturedLegacySession { return locator.utf8.elementsEqual(capturedLegacySession.logicalLocator.utf8) }
        if let modern = decodeModernLocator(locator) {
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

    private struct LegacyMessageReadResult {
        let messages: [NormalizedMessage]
        let hasMoreMessages: Bool
    }

    private func loadMessages(
        locator: String,
        locatorParts: (dbPath: String, composerId: String)
    ) async throws -> LegacyMessageReadResult {
        let signature = capturedLegacySession == nil ? ParsedTranscriptCache.Signature.forFile(locatorParts.dbPath) : nil
        if let cached = await messageCache.cached(locator: locator, signature: signature) {
            return LegacyMessageReadResult(messages: cached, hasMoreMessages: false)
        }
        do {
            let database = try legacyDatabase(locator: locator, path: locatorParts.dbPath)
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
                composerId: locatorParts.composerId,
                maxMessages: limits.maxMessages
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
            if !bubbleResult.hasMoreMessages {
                await messageCache.store(locator: locator, signature: signature, messages: messages)
            }
            return LegacyMessageReadResult(
                messages: messages,
                hasMoreMessages: bubbleResult.hasMoreMessages
            )
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
            let projection = try modernMetadata(modern)
            let metadata = projection.metadata
            let firstUser = messages.first { $0.role == .user }?.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let primaryModification = capturedPrimaryMtimeNs.map { Double($0) / 1_000_000 }
                ?? Self.modificationMilliseconds(for: modern.transcriptPath ?? modern.storeDBPath)
            let createdAt = Phase4AdapterSupport.double(metadata["createdAtMs"])
                ?? Phase4AdapterSupport.double(metadata["createdAt"])
                ?? primaryModification
                ?? 0
            let updatedAt = primaryModification ?? createdAt
            let officialName = Self.officialTitle(from: metadata)
            let cwd = projection.cwd
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
        let (storeURL, before) = try JSONLAdapterSupport.prepareFile(
            locator: storeDBPath,
            limits: limits
        )
        let database = try modernDatabase(path: storeDBPath)
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
        testHooks.beforeModernIdentityValidation()
        let parseFailure: ParserFailure?
        do {
            let after = try limits.fileIdentity(for: storeURL)
            parseFailure = limits.isSameFileIdentity(before, after)
                ? nil
                : .fileModifiedDuringParse
        } catch {
            parseFailure = .fileModifiedDuringParse
        }
        return ModernMessageReadResult(
            messages: Array(messages.prefix(limits.maxMessages)),
            parseFailure: parseFailure,
            hasMoreMessages: messages.count > limits.maxMessages
        )
    }

    private func modernMetadata(_ modern: ModernLocator) throws -> SourceMetadataProjection.CursorModernMetadata {
        guard let storeDBPath = modern.storeDBPath else {
            return SourceMetadataProjection.cursorModernMetadata(storedText: nil, liveText: nil)
        }
        let database = try modernDatabase(path: storeDBPath)
        let storedText = try database.query("SELECT value FROM meta WHERE key = '0' LIMIT 1").first?["value"] ?? nil
        let metaPath = URL(fileURLWithPath: storeDBPath)
            .deletingLastPathComponent()
            .appendingPathComponent("meta.json")
        let liveText = try? JSONLAdapterSupport.readString(locator: metaPath.path, limits: limits)
        return SourceMetadataProjection.cursorModernMetadata(storedText: storedText, liveText: liveText)
    }

    private func modernDatabase(path: String) throws -> Phase4SQLiteDatabase {
        // A captured main-only database may retain a WAL-mode header. Immutable
        // mode reads those verified pages without requiring/creating sidecars.
        // Never use it when a WAL member exists: that would ignore its frames.
        let locator = capturedWALAbsent
            ? URL(fileURLWithPath: path).absoluteString + "?immutable=1" : path
        return try Phase4SQLiteDatabase(path: locator)
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

    private static func decodeEncodedModernLocator(_ locator: String) -> ModernLocator? {
        guard locator.hasPrefix(modernLocatorPrefix),
              let data = Data(base64Encoded: String(locator.dropFirst(modernLocatorPrefix.count)))
        else { return nil }
        return try? JSONDecoder().decode(ModernLocator.self, from: data)
    }

    private func decodeModernLocator(_ locator: String) -> ModernLocator? {
        guard let decoded = Self.decodeEncodedModernLocator(locator) else { return nil }
        return confinedModernLocator(decoded)
    }

    private func confinedModernLocator(_ locator: ModernLocator) -> ModernLocator? {
        guard Self.isSafeModernSessionID(locator.sessionId) else { return nil }
        var confined = locator
        if let storeDBPath = locator.storeDBPath {
            guard let path = confinedModernPath(
                storeDBPath,
                expectedSubdirectory: "chats",
                expectedRelativeComponents: [nil, locator.sessionId, "store.db"]
            ) else { return nil }
            confined.storeDBPath = path
        }
        if let transcriptPath = locator.transcriptPath {
            guard let path = confinedModernPath(
                transcriptPath,
                expectedSubdirectory: "projects",
                expectedRelativeComponents: [nil, "agent-transcripts", locator.sessionId, "\(locator.sessionId).jsonl"]
            ) else { return nil }
            confined.transcriptPath = path
        }
        guard confined.storeDBPath != nil || confined.transcriptPath != nil else { return nil }
        return confined
    }

    private func confinedModernPath(
        _ rawPath: String,
        expectedSubdirectory: String,
        expectedRelativeComponents: [String?]
    ) -> String? {
        let rawComponents = rawPath.split(separator: "/", omittingEmptySubsequences: false)
        guard rawPath.hasPrefix("/"),
              !rawPath.utf8.contains(0),
              !rawComponents.contains("."),
              !rawComponents.contains("..")
        else { return nil }

        let lexicalURL = URL(fileURLWithPath: rawPath).standardizedFileURL
        let declaredRoot = cursorDataRoot
            .appendingPathComponent(expectedSubdirectory, isDirectory: true)
            .standardizedFileURL
        guard let physicalRoot = Self.physicalURLResolvingExistingAncestors(declaredRoot),
              let physicalURL = Self.physicalURLResolvingExistingAncestors(lexicalURL),
              let relative = Self.relativeComponents(of: physicalURL, under: physicalRoot),
              relative.count == expectedRelativeComponents.count
        else { return nil }
        for (actual, expected) in zip(relative, expectedRelativeComponents) {
            if let expected, actual != expected { return nil }
        }
        return physicalURL.path
    }

    private static func isSafeModernSessionID(_ sessionID: String) -> Bool {
        !sessionID.isEmpty
            && sessionID != "."
            && sessionID != ".."
            && !sessionID.contains("/")
            && !sessionID.utf8.contains(0)
    }

    private static func relativeComponents(of path: URL, under root: URL) -> [String]? {
        let pathComponents = path.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard pathComponents.count > rootComponents.count,
              Array(pathComponents.prefix(rootComponents.count)) == rootComponents
        else { return nil }
        return Array(pathComponents.dropFirst(rootComponents.count))
    }

    private static func physicalURLResolvingExistingAncestors(_ url: URL) -> URL? {
        var ancestor = url.standardizedFileURL
        var missingComponents: [String] = []
        if let resolved = realPath(ancestor.path) {
            return missingComponents.reduce(URL(fileURLWithPath: resolved)) { partial, component in
                partial.appendingPathComponent(component)
            }
            .standardizedFileURL
        }
        repeat {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { return nil }
            missingComponents.insert(ancestor.lastPathComponent, at: 0)
            ancestor = parent
            if let resolved = realPath(ancestor.path) {
                return missingComponents.reduce(URL(fileURLWithPath: resolved)) { partial, component in
                    partial.appendingPathComponent(component)
                }
                .standardizedFileURL
            }
        } while ancestor.path != "/"
        return nil
    }

    private static func realPath(_ path: String) -> String? {
        path.withCString { rawPath in
            guard let resolved = Darwin.realpath(rawPath, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    private static func modificationMilliseconds(for path: String?) -> Double? {
        guard let path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attributes[.modificationDate] as? Date
        else { return nil }
        return date.timeIntervalSince1970 * 1_000
    }

    private static func modernInputPaths(_ modern: ModernLocator) -> [String] {
        var paths = [modern.storeDBPath, modern.transcriptPath].compactMap { $0 }
        if let storeDBPath = modern.storeDBPath {
            paths.append(
                URL(fileURLWithPath: storeDBPath)
                    .deletingLastPathComponent()
                    .appendingPathComponent("meta.json")
                    .path
            )
        }
        return Array(Set(paths))
    }

    private static func compositeModificationDate(
        _ modern: ModernLocator,
        fileManager: FileManager
    ) -> Date? {
        modernInputPaths(modern).compactMap { path in
            try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date
        }
        .max()
    }

    private static func compositeInputIdentity(_ modern: ModernLocator) -> IndexingInputIdentity? {
        let primaryPath = modern.transcriptPath ?? modern.storeDBPath
        var totalSize: Int64 = 0
        var newestNanos: Int64 = 0
        var primaryInode: Int64?
        var primaryDevice: Int64?
        var foundPrimary = false

        for path in modernInputPaths(modern) {
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            totalSize += Int64(info.st_size)
            let modifiedNanos = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000
                + Int64(info.st_mtimespec.tv_nsec)
            newestNanos = max(newestNanos, modifiedNanos)
            if path == primaryPath {
                foundPrimary = true
                primaryInode = Int64(info.st_ino)
                primaryDevice = Int64(info.st_dev)
            }
        }

        guard foundPrimary else { return nil }
        return IndexingInputIdentity(
            sizeBytes: totalSize,
            modifiedAtNanos: newestNanos,
            locatorInode: primaryInode,
            locatorDevice: primaryDevice
        )
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
        let hasMoreMessages: Bool
    }

    private static func bubbles(
        database: Phase4SQLiteDatabase,
        composerData: Phase4AdapterSupport.JSONObject,
        composerId: String,
        maxMessages: Int
    ) throws -> BubbleLoadResult {
        let boundedMaxMessages = max(maxMessages, 0)
        let pageLimit = boundedMaxMessages == Int.max ? Int.max : boundedMaxMessages + 1
        if let conversation = JSONLAdapterSupport.array(composerData["conversation"]),
           !conversation.isEmpty
        {
            var visibleBubbles: [Phase4AdapterSupport.JSONObject] = []
            for value in conversation {
                guard let bubble = JSONLAdapterSupport.object(value),
                      visibleBubble(bubble) != nil
                else { continue }
                visibleBubbles.append(bubble)
                if visibleBubbles.count > boundedMaxMessages { break }
            }
            return BubbleLoadResult(
                bubbles: Array(visibleBubbles.prefix(boundedMaxMessages)),
                rawBubbleBytes: 0,
                hasMoreMessages: visibleBubbles.count > boundedMaxMessages
            )
        }

        var visibleBubbles: [Phase4AdapterSupport.JSONObject] = []
        var rawBytes: Int64 = 0
        var offset = 0
        while true {
            let rows = try database.query(
                "SELECT value FROM cursorDiskKV WHERE key LIKE ? ORDER BY rowid ASC LIMIT \(pageLimit) OFFSET \(offset)",
                bindings: ["bubbleId:\(composerId):%"]
            )
            guard !rows.isEmpty else { break }
            for row in rows {
                guard let value = row["value"] ?? nil else { continue }
                rawBytes += Int64(value.utf8.count)
                guard let object = Phase4AdapterSupport.jsonObject(from: value),
                      visibleBubble(object) != nil
                else { continue }
                visibleBubbles.append(object)
                if visibleBubbles.count > boundedMaxMessages {
                    return BubbleLoadResult(
                        bubbles: Array(visibleBubbles.prefix(boundedMaxMessages)),
                        rawBubbleBytes: rawBytes,
                        hasMoreMessages: true
                    )
                }
            }
            if rows.count < pageLimit { break }
            let (nextOffset, overflow) = offset.addingReportingOverflow(rows.count)
            guard !overflow else { throw ParserFailure.messageLimitExceeded }
            offset = nextOffset
        }
        return BubbleLoadResult(
            bubbles: visibleBubbles,
            rawBubbleBytes: rawBytes,
            hasMoreMessages: false
        )
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
