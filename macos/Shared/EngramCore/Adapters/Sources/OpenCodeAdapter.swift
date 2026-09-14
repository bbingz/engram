import Foundation
import SQLite3

public enum OpenCodeSessionRoleClassifier {
    public static func isDispatchedChild(
        parentSessionId: String?,
        title: String,
        agent: String?,
        slug: String?
    ) -> Bool {
        guard parentSessionId != nil else { return false }
        let normalizedAgent = agent?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isNonPrimaryAgent = normalizedAgent.map {
            !$0.isEmpty && $0 != "build" && $0 != "plan"
        } ?? false
        let normalizedSlug = slug?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return isNonPrimaryAgent
            || normalizedSlug.hasPrefix("task-")
            || isTaskToolTitle(title)
    }

    private static func isTaskToolTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.hasSuffix(" subagent)"),
              let marker = normalized.range(of: " (@", options: .backwards)
        else {
            return false
        }
        return marker.upperBound < normalized.index(normalized.endIndex, offsetBy: -" subagent)".count)
    }
}

final class Phase4SQLiteDatabase {
    private var database: OpaquePointer?

    init(path: String) throws {
        let result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard result == SQLITE_OK else {
            sqlite3_close(database)
            database = nil
            throw ParserFailure.sqliteUnreadable
        }
        sqlite3_busy_timeout(database, 30000)
    }

    /// Reconstruct only validated session rows. No source database or sidecar
    /// is opened; query() retains the native SQLite-to-String conversion.
    init(cursorLegacySession: ArchiveCursorLegacySession) throws {
        guard sqlite3_open(":memory:", &database) == SQLITE_OK else {
            sqlite3_close(database)
            database = nil
            throw ParserFailure.sqliteUnreadable
        }
        do {
            try execute("CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value);")
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database,
                "INSERT INTO cursorDiskKV(rowid, key, value) VALUES (?, ?, ?)",
                -1, &statement, nil) == SQLITE_OK, let statement else {
                throw ParserFailure.sqliteUnreadable
            }
            defer { sqlite3_finalize(statement) }
            for row in [cursorLegacySession.composer] + cursorLegacySession.bubbles {
                try Task.checkCancellation()
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                guard sqlite3_bind_int64(statement, 1, row.rowID) == SQLITE_OK,
                      sqlite3_bind_text(statement, 2, row.key, Int32(row.key.utf8.count),
                        Self.transientDestructor) == SQLITE_OK else { throw ParserFailure.sqliteUnreadable }
                let status: Int32
                if let value = row.value {
                    if value.isEmpty {
                        status = row.storage == .blob ? sqlite3_bind_zeroblob(statement, 3, 0)
                            : sqlite3_bind_text(statement, 3, "", 0, Self.transientDestructor)
                    } else {
                        status = value.withUnsafeBytes { bytes in
                            row.storage == .blob
                                ? sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(value.count), Self.transientDestructor)
                                : sqlite3_bind_text(statement, 3, bytes.bindMemory(to: Int8.self).baseAddress,
                                    Int32(value.count), Self.transientDestructor)
                        }
                    }
                } else {
                    status = sqlite3_bind_null(statement, 3)
                }
                guard status == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
                    throw ParserFailure.sqliteUnreadable
                }
            }
            try execute("PRAGMA query_only=ON;")
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw ParserFailure.sqliteUnreadable
        }
    }

    func query(_ sql: String, bindings: [String] = []) throws -> [[String: String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ParserFailure.sqliteUnreadable
        }
        defer { sqlite3_finalize(statement) }

        for (index, binding) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), binding, -1, Self.transientDestructor)
        }

        var rows: [[String: String?]] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE {
                return rows
            }
            guard stepResult == SQLITE_ROW else {
                throw ParserFailure.sqliteUnreadable
            }

            var row: [String: String?] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                guard let namePointer = sqlite3_column_name(statement, column) else { continue }
                let name = String(cString: namePointer)
                if sqlite3_column_type(statement, column) == SQLITE_NULL {
                    row[name] = nil
                } else if let textPointer = sqlite3_column_text(statement, column) {
                    row[name] = String(cString: textPointer)
                } else {
                    row[name] = nil
                }
            }
            rows.append(row)
        }
    }

    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

actor Phase4SQLiteAccessibilityCache {
    private var databases: [String: Phase4SQLiteDatabase] = [:]

    func contains(path: String, sql: String, bindings: [String]) -> Bool {
        guard JSONLAdapterSupport.fileExists(path) else {
            databases.removeValue(forKey: path)
            return false
        }

        do {
            let database: Phase4SQLiteDatabase
            if let cached = databases[path] {
                database = cached
            } else {
                let opened = try Phase4SQLiteDatabase(path: path)
                databases[path] = opened
                database = opened
            }
            return (try database.query(sql, bindings: bindings)).isEmpty == false
        } catch {
            databases.removeValue(forKey: path)
            return false
        }
    }
}

final class OpenCodeAdapter: SessionAdapter, ModificationFilteredSessionAdapter, Sendable {
    let source: SourceName = .opencode
    private let dbPath: String
    private let limits: ParserLimits
    private let accessibilityCache = Phase4SQLiteAccessibilityCache()

    init(
        dbPath: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
            .path,
        limits: ParserLimits = .default
    ) {
        self.dbPath = dbPath
        self.limits = limits
    }

    /// Reads only the staged session image. Logical locators stay metadata.
    static func scanCapturedSource(
        physicalLocator: String,
        logicalLocator: String,
        context: ArchiveSQLiteSessionContext
    ) async throws -> AdapterParseResult<CapturedSourceScan> {
        try Task.checkCancellation()
        guard exact(logicalLocator, context.databaseLocator + "::" + context.nativeSessionID),
              !exact(physicalLocator, context.databaseLocator) else {
            return .failure(.malformedJSON)
        }
        do {
            try requireScopedCapturedImage(path: physicalLocator, context: context)
        } catch let failure as ParserFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedJSON)
        }
        switch try await OpenCodeAdapter(dbPath: physicalLocator).scanForIndexing(
            locator: physicalLocator + "::" + context.nativeSessionID
        ) {
        case .failure(let error):
            return .failure(error)
        case .success(var scan):
            scan.info.filePath = logicalLocator
            return .success(CapturedSourceScan(scan: scan, rawSourceSessionID: context.nativeSessionID))
        }
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.fileExists(dbPath)
    }

    func listSessionLocators() async throws -> [String] {
        try listSessionLocators(modifiedSinceMilliseconds: nil)
    }

    func listSessionLocators(
        modifiedSince: Date,
        fileManager _: FileManager
    ) async throws -> [String] {
        let cutoffMilliseconds = Int64(
            (modifiedSince.timeIntervalSince1970 * 1_000).rounded(.down)
        )
        return try listSessionLocators(modifiedSinceMilliseconds: cutoffMilliseconds)
    }

    private func listSessionLocators(modifiedSinceMilliseconds: Int64?) throws -> [String] {
        guard JSONLAdapterSupport.fileExists(dbPath) else { return [] }
        let database = try Phase4SQLiteDatabase(path: dbPath)
        let hasParentID = try database.query("PRAGMA table_info(session)")
            .contains { ($0["name"] ?? nil) == "parent_id" }
        let modificationClause = modifiedSinceMilliseconds.map { _ in " AND time_updated >= ?" } ?? ""
        let bindings = modifiedSinceMilliseconds.map { [String($0)] } ?? []
        let parentOrder = hasParentID ? "CASE WHEN parent_id IS NULL THEN 0 ELSE 1 END," : ""
        return try database.query(
            """
            SELECT id
            FROM session
            WHERE time_archived IS NULL\(modificationClause)
            ORDER BY \(parentOrder) time_updated DESC
            """,
            bindings: bindings
        )
        .compactMap { row in row["id"] ?? nil }
        .map { "\(dbPath)::\($0)" }
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        guard let locatorParts = Self.splitVirtualLocator(locator) else {
            return .failure(.unsupportedVirtualLocator)
        }

        do {
            let database = try Phase4SQLiteDatabase(path: locatorParts.dbPath)
            let sessionColumns = Set(
                try database.query("PRAGMA table_info(session)")
                    .compactMap { $0["name"] ?? nil }
            )
            let optionalColumns = ["parent_id", "slug", "agent"]
                .filter(sessionColumns.contains)
                .map { ", \($0)" }
                .joined()
            guard let session = try database.query(
                """
                SELECT id, directory, title, time_created, time_updated\(optionalColumns)
                FROM session
                WHERE id = ? AND time_archived IS NULL
                """,
                bindings: [locatorParts.sessionId]
            ).first else {
                return .failure(.malformedJSON)
            }

            let boundedMessages = try Self.boundedMessages(
                database: database,
                sessionId: locatorParts.sessionId,
                maxMessages: limits.maxMessages
            )
            let userCount = boundedMessages.messages.lazy.filter { $0.role == .user }.count
            let assistantCount = boundedMessages.messages.lazy.filter { $0.role == .assistant }.count
            // R184-3: a live session row with no contentful user/assistant
            // text must not become a zero-count browsable session.
            guard userCount + assistantCount > 0 else {
                return .failure(.noVisibleMessages)
            }
            if boundedMessages.hasMoreMessages {
                return .failure(.messageLimitExceeded)
            }

            let sessionCreated = Phase4AdapterSupport.double(session["time_created"] ?? nil) ?? 0
            let firstMessageTime = try Self.messageTime(
                database: database,
                sessionId: locatorParts.sessionId,
                descending: false
            )
            let lastMessageTime = try Self.messageTime(
                database: database,
                sessionId: locatorParts.sessionId,
                descending: true
            )
            let startTime = Phase4AdapterSupport.isoFromMilliseconds(firstMessageTime ?? sessionCreated)
            let parentSessionID = session["parent_id"] ?? nil
            let title = (session["title"] ?? nil) ?? ""
            let isTaskChild = OpenCodeSessionRoleClassifier.isDispatchedChild(
                parentSessionId: parentSessionID,
                title: title,
                agent: session["agent"] ?? nil,
                slug: session["slug"] ?? nil
            )

            return .success(
                NormalizedSessionInfo(
                    id: (session["id"] ?? nil) ?? locatorParts.sessionId,
                    source: .opencode,
                    startTime: startTime,
                    endTime: userCount + assistantCount > 1 && lastMessageTime != nil
                        ? Phase4AdapterSupport.isoFromMilliseconds(lastMessageTime!)
                        : nil,
                    cwd: (session["directory"] ?? nil) ?? "",
                    project: nil,
                    model: nil,
                    messageCount: userCount + assistantCount,
                    userMessageCount: userCount,
                    assistantMessageCount: assistantCount,
                    toolMessageCount: 0,
                    systemMessageCount: 0,
                    summary: {
                        return title.isEmpty ? nil : title
                    }(),
                    filePath: locator,
                    sizeBytes: try Self.sessionPayloadSize(database: database, sessionId: locatorParts.sessionId),
                    indexedAt: nil,
                    // docs/invariants.md #2: only true task/subagent children
                    // enter dispatched/skip; a continued fork keeps its parent
                    // link without being hidden.
                    agentRole: isTaskChild ? "dispatched" : nil,
                    originator: nil,
                    origin: nil,
                    summaryMessageCount: nil,
                    tier: nil,
                    qualityScore: nil,
                    parentSessionId: parentSessionID,
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
        let result = try Self.messages(locator: locator, options: options, maxMessages: limits.maxMessages)
        if options.limit == nil, result.truncatedAt != nil {
            throw ParserFailure.messageLimitExceeded
        }
        return JSONLAdapterSupport.stream(result.messages)
    }

    func streamMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> StreamMessagesResult {
        let result = try Self.messages(locator: locator, options: options, maxMessages: limits.maxMessages)
        return JSONLAdapterSupport.stream(result)
    }

    func isAccessible(locator: String) async -> Bool {
        guard let locatorParts = Self.splitVirtualLocator(locator) else {
            return false
        }
        // Archive is soft-delete (`time_archived` set). Discovery/parse already
        // exclude archived rows; accessibility must match so indexed rows can
        // enter the orphan lifecycle instead of remaining indefinitely visible.
        return await accessibilityCache.contains(
            path: locatorParts.dbPath,
            sql:
            "SELECT 1 FROM session WHERE id = ? AND time_archived IS NULL LIMIT 1",
            bindings: [locatorParts.sessionId]
        )
    }

    private static func messages(
        locator: String,
        options: StreamMessagesOptions,
        maxMessages: Int
    ) throws -> JSONLAdapterSupport.WindowedMessagesResult {
        guard let locatorParts = Self.splitVirtualLocator(locator) else {
            throw ParserFailure.unsupportedVirtualLocator
        }

        do {
            let database = try Phase4SQLiteDatabase(path: locatorParts.dbPath)
            let result = try boundedMessages(
                database: database,
                sessionId: locatorParts.sessionId,
                maxMessages: maxMessages
            )
            return JSONLAdapterSupport.boundedWindowWithMetadata(
                result.messages,
                options: options,
                maxMessages: maxMessages,
                hasMoreMessages: result.hasMoreMessages
            )
        } catch let failure as ParserFailure {
            throw failure
        } catch {
            throw ParserFailure.sqliteUnreadable
        }
    }

    private struct BoundedMessagesResult {
        let messages: [NormalizedMessage]
        let hasMoreMessages: Bool
    }

    private static func boundedMessages(
        database: Phase4SQLiteDatabase,
        sessionId: String,
        maxMessages: Int
    ) throws -> BoundedMessagesResult {
        let cap = max(maxMessages, 0)
        let pageSize = min(max(cap == Int.max ? Int.max : cap + 1, 1), 512)
        var offset = 0
        var messages: [NormalizedMessage] = []
        var indexByMessageId: [String: Int] = [:]

        while true {
            let rows = try database.query(
                """
                SELECT m.id AS mid, m.data AS mdata, p.data AS pdata, m.time_created
                FROM message m
                JOIN part p ON p.message_id = m.id
                WHERE m.session_id = ?
                ORDER BY m.time_created ASC, m.id ASC, p.time_created ASC, p.id ASC
                LIMIT \(pageSize) OFFSET \(offset)
                """,
                bindings: [sessionId]
            )
            guard !rows.isEmpty else {
                return BoundedMessagesResult(messages: messages, hasMoreMessages: false)
            }

            for row in rows {
                guard let part = messagePart(from: row) else { continue }
                if let index = indexByMessageId[part.messageId] {
                    messages[index].content += "\n\(part.content)"
                    continue
                }
                guard messages.count < cap else {
                    return BoundedMessagesResult(messages: messages, hasMoreMessages: true)
                }
                indexByMessageId[part.messageId] = messages.count
                messages.append(
                    NormalizedMessage(
                        role: part.role,
                        content: part.content,
                        timestamp: part.timestamp,
                        toolCalls: nil,
                        usage: part.usage
                    )
                )
            }

            guard rows.count == pageSize else {
                return BoundedMessagesResult(messages: messages, hasMoreMessages: false)
            }
            offset += rows.count
        }
    }

    private static func messageTime(
        database: Phase4SQLiteDatabase,
        sessionId: String,
        descending: Bool
    ) throws -> Double? {
        let row = try database.query(
            """
            SELECT time_created
            FROM message
            WHERE session_id = ?
            ORDER BY time_created \(descending ? "DESC" : "ASC")
            LIMIT 1
            """,
            bindings: [sessionId]
        ).first
        return Phase4AdapterSupport.double(row?["time_created"] ?? nil)
    }

    private static func requireScopedCapturedImage(
        path: String,
        context: ArchiveSQLiteSessionContext
    ) throws {
        guard JSONLAdapterSupport.fileExists(path), !exact(path, context.databaseLocator) else {
            throw ParserFailure.malformedJSON
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let fileSize = (attributes[.size] as? NSNumber)?.int64Value, fileSize >= 100 else {
            throw ParserFailure.malformedJSON
        }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path, isDirectory: false))
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 100), header.count == 100,
              header.starts(with: Data("SQLite format 3\0".utf8)),
              header[18] == 1, header[19] == 1 else {
            throw ParserFailure.malformedJSON
        }
        var pageSize = Int(header[16]) << 8 | Int(header[17])
        if pageSize == 1 { pageSize = 65536 }
        guard [512, 1024, 2048, 4096, 8192, 16384, 32768, 65536].contains(pageSize),
              fileSize % Int64(pageSize) == 0 else {
            throw ParserFailure.malformedJSON
        }

        let database = try Phase4SQLiteDatabase(path: path)
        try database.execute("PRAGMA query_only = ON")
        try database.execute("PRAGMA temp_store = MEMORY")
        try requireApplicationSchema(database)
        let pageCount = try firstInteger(database, "PRAGMA page_count")
        let pragmaPageSize = try firstInteger(database, "PRAGMA page_size")
        let geometry = pragmaPageSize.multipliedReportingOverflow(by: pageCount)
        guard !geometry.overflow, geometry.partialValue == fileSize,
              pragmaPageSize == Int64(pageSize),
              try firstInteger(database, "PRAGMA freelist_count") == 0 else {
            throw ParserFailure.malformedJSON
        }
        guard try firstInteger(database, "SELECT count(*) AS value FROM session") == 1 else {
            throw ParserFailure.malformedJSON
        }
        let sessionID = try database.query("SELECT id FROM session LIMIT 2").first?["id"] ?? nil
        guard let sessionID, exact(sessionID, context.nativeSessionID) else {
            throw ParserFailure.malformedJSON
        }
        guard try database.query(
            """
            SELECT 1 AS value FROM message
            WHERE typeof(id) != 'text' OR typeof(session_id) != 'text'
                OR session_id != ? COLLATE BINARY
            LIMIT 1
            """,
            bindings: [context.nativeSessionID]
        ).isEmpty else {
            throw ParserFailure.malformedJSON
        }
        guard try database.query(
            """
            SELECT 1 AS value FROM part p
            WHERE typeof(p.message_id) != 'text' OR NOT EXISTS (
                SELECT 1 FROM message m
                WHERE m.id = p.message_id COLLATE BINARY
                    AND m.session_id = ? COLLATE BINARY
            )
            LIMIT 1
            """,
            bindings: [context.nativeSessionID]
        ).isEmpty else {
            throw ParserFailure.malformedJSON
        }
        guard try sessionPayloadSize(database: database, sessionId: context.nativeSessionID)
            == context.nativePayloadByteCount else {
            throw ParserFailure.malformedJSON
        }
    }

    private static func requireApplicationSchema(_ database: Phase4SQLiteDatabase) throws {
        let rows = try database.query("SELECT type, name, sql FROM sqlite_schema")
        var tables = Set<String>()
        for row in rows {
            let type = (row["type"] ?? nil) ?? ""
            let name = (row["name"] ?? nil) ?? ""
            let sql = (row["sql"] ?? nil) ?? ""
            if name.hasPrefix("sqlite_") { continue }
            if type == "index" { continue }
            guard type == "table", ["session", "message", "part"].contains(name),
                  !sql.uppercased().contains("CREATE VIRTUAL TABLE") else {
                throw ParserFailure.malformedJSON
            }
            tables.insert(name)
        }
        guard tables == Set(["session", "message", "part"]) else {
            throw ParserFailure.malformedJSON
        }
    }

    private static func firstInteger(
        _ database: Phase4SQLiteDatabase,
        _ sql: String,
        bindings: [String] = []
    ) throws -> Int64 {
        guard let row = try database.query(sql, bindings: bindings).first,
              let raw = row.values.compactMap({ $0 }).first,
              let value = Int64(raw) else {
            throw ParserFailure.malformedJSON
        }
        return value
    }

    private static func exact(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private static func splitVirtualLocator(_ locator: String) -> (dbPath: String, sessionId: String)? {
        guard let range = locator.range(of: "::", options: .backwards) else { return nil }
        return (
            dbPath: String(locator[..<range.lowerBound]),
            sessionId: String(locator[range.upperBound...])
        )
    }

    private static func sessionPayloadSize(
        database: Phase4SQLiteDatabase,
        sessionId: String
    ) throws -> Int64 {
        // SQLite length(TEXT) is characters; CAST AS BLOB yields UTF-8 bytes so CJK
        // payloads are not under-counted for UI size and offload ranking.
        let messageBytes = try queryByteSum(
            database,
            sql: "SELECT COALESCE(SUM(length(CAST(data AS BLOB))), 0) AS bytes FROM message WHERE session_id = ?",
            sessionId: sessionId
        )
        let partBytes = try queryByteSum(
            database,
            sql: """
            SELECT COALESCE(SUM(length(CAST(p.data AS BLOB))), 0) AS bytes
            FROM part p
            JOIN message m ON m.id = p.message_id
            WHERE m.session_id = ?
            """,
            sessionId: sessionId
        )
        return messageBytes + partBytes
    }

    private static func queryByteSum(
        _ database: Phase4SQLiteDatabase,
        sql: String,
        sessionId: String
    ) throws -> Int64 {
        let raw = try database.query(sql, bindings: [sessionId]).first?["bytes"] ?? nil
        return Int64(raw ?? "") ?? 0
    }

    private struct MessagePart {
        let messageId: String
        let role: NormalizedMessageRole
        let content: String
        let timestamp: String?
        let usage: TokenUsage?
    }

    private static func messagePart(from row: [String: String?]) -> MessagePart? {
        guard let messageId = row["mid"] ?? nil,
              let rawMessage = row["mdata"] ?? nil,
              let rawPart = row["pdata"] ?? nil,
              let messageData = Phase4AdapterSupport.jsonObject(from: rawMessage),
              let partData = Phase4AdapterSupport.jsonObject(from: rawPart),
              let role = JSONLAdapterSupport.string(messageData["role"]),
              role == "user" || role == "assistant",
              isTextPart(partData)
        else {
            return nil
        }

        let content = JSONLAdapterSupport.string(partData["text"]) ??
            JSONLAdapterSupport.string(partData["value"]) ?? ""
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let timestamp = Phase4AdapterSupport.double(row["time_created"] ?? nil)
            .map { Phase4AdapterSupport.isoFromMilliseconds($0) }
        return MessagePart(
            messageId: messageId,
            role: role == "user" ? .user : .assistant,
            content: content,
            timestamp: timestamp,
            usage: role == "assistant" ? usage(from: JSONLAdapterSupport.object(messageData["tokens"])) : nil
        )
    }

    private static func usage(from tokens: Phase4AdapterSupport.JSONObject?) -> TokenUsage? {
        guard let tokens else { return nil }
        let cache = JSONLAdapterSupport.object(tokens["cache"])
        let usage = TokenUsage(
            inputTokens: int(tokens["input"]),
            outputTokens: int(tokens["output"]) + int(tokens["reasoning"]),
            cacheReadTokens: int(cache?["read"]),
            cacheCreationTokens: int(cache?["write"])
        )
        guard usage.inputTokens > 0
            || usage.outputTokens > 0
            || (usage.cacheReadTokens ?? 0) > 0
            || (usage.cacheCreationTokens ?? 0) > 0
        else {
            return nil
        }
        return usage
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func isTextPart(_ partData: Phase4AdapterSupport.JSONObject) -> Bool {
        JSONLAdapterSupport.string(partData["type"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "text"
    }
}
