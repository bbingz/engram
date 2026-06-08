import Foundation
import SQLite3

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

    deinit {
        sqlite3_close(database)
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

final class OpenCodeAdapter: SessionAdapter, Sendable {
    let source: SourceName = .opencode
    private let dbPath: String
    private let accessibilityCache = Phase4SQLiteAccessibilityCache()

    init(
        dbPath: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
            .path
    ) {
        self.dbPath = dbPath
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.fileExists(dbPath)
    }

    func listSessionLocators() async throws -> [String] {
        guard JSONLAdapterSupport.fileExists(dbPath) else { return [] }
        do {
            let database = try Phase4SQLiteDatabase(path: dbPath)
            return try database.query(
                """
                SELECT id, directory, title, time_created, time_updated
                FROM session
                WHERE time_archived IS NULL
                ORDER BY time_updated DESC
                """
            )
            .compactMap { row in row["id"] ?? nil }
            .map { "\(dbPath)::\($0)" }
        } catch {
            return []
        }
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        guard let locatorParts = Self.splitVirtualLocator(locator) else {
            return .failure(.unsupportedVirtualLocator)
        }

        do {
            let database = try Phase4SQLiteDatabase(path: locatorParts.dbPath)
            guard let session = try database.query(
                """
                SELECT id, directory, title, time_created, time_updated
                FROM session
                WHERE id = ? AND time_archived IS NULL
                """,
                bindings: [locatorParts.sessionId]
            ).first else {
                return .failure(.malformedJSON)
            }

            let messages = try database.query(
                """
                SELECT id, session_id, time_created, data
                FROM message
                WHERE session_id = ?
                ORDER BY time_created ASC
                """,
                bindings: [locatorParts.sessionId]
            )

            // Count only messages that contribute a non-empty text part, mirroring
            // the streamMessages predicate so counts match the streamed transcript.
            let countRows = try database.query(
                """
                SELECT m.id AS mid, m.data AS mdata, p.data AS pdata
                FROM message m
                JOIN part p ON p.message_id = m.id
                WHERE m.session_id = ?
                """,
                bindings: [locatorParts.sessionId]
            )
            var userMessageIds = Set<String>()
            var assistantMessageIds = Set<String>()
            for row in countRows {
                guard let messageId = row["mid"] ?? nil,
                      let role = Self.contentfulRole(from: row)
                else {
                    continue
                }
                if role == "user" {
                    userMessageIds.insert(messageId)
                } else if role == "assistant" {
                    assistantMessageIds.insert(messageId)
                }
            }
            let userCount = userMessageIds.count
            let assistantCount = assistantMessageIds.count

            let sessionCreated = Phase4AdapterSupport.double(session["time_created"] ?? nil) ?? 0
            let firstMessageTime = Phase4AdapterSupport.double(messages.first?["time_created"] ?? nil)
            let lastMessageTime = Phase4AdapterSupport.double(messages.last?["time_created"] ?? nil)
            let startTime = Phase4AdapterSupport.isoFromMilliseconds(firstMessageTime ?? sessionCreated)

            return .success(
                NormalizedSessionInfo(
                    id: (session["id"] ?? nil) ?? locatorParts.sessionId,
                    source: .opencode,
                    startTime: startTime,
                    endTime: messages.count > 1 && lastMessageTime != nil
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
                        let title = (session["title"] ?? nil) ?? ""
                        return title.isEmpty ? nil : title
                    }(),
                    filePath: locator,
                    sizeBytes: try Self.sessionPayloadSize(database: database, sessionId: locatorParts.sessionId),
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
        guard let locatorParts = Self.splitVirtualLocator(locator) else {
            throw ParserFailure.unsupportedVirtualLocator
        }

        do {
            let database = try Phase4SQLiteDatabase(path: locatorParts.dbPath)
            let rows = try database.query(
                """
                SELECT m.id AS mid, m.data AS mdata, p.data AS pdata, m.time_created
                FROM message m
                JOIN part p ON p.message_id = m.id
                WHERE m.session_id = ?
                ORDER BY m.time_created ASC, p.time_created ASC
                """,
                bindings: [locatorParts.sessionId]
            )
            let messages = Self.messages(from: rows)
            return JSONLAdapterSupport.stream(JSONLAdapterSupport.applyWindow(messages, options: options))
        } catch let failure as ParserFailure {
            throw failure
        } catch {
            throw ParserFailure.sqliteUnreadable
        }
    }

    func isAccessible(locator: String) async -> Bool {
        guard let locatorParts = Self.splitVirtualLocator(locator) else {
            return false
        }
        return await accessibilityCache.contains(
            path: locatorParts.dbPath,
            sql:
            "SELECT 1 FROM session WHERE id = ? LIMIT 1",
            bindings: [locatorParts.sessionId]
        )
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
        let messageBytes = try queryByteSum(
            database,
            sql: "SELECT COALESCE(SUM(length(data)), 0) AS bytes FROM message WHERE session_id = ?",
            sessionId: sessionId
        )
        let partBytes = try queryByteSum(
            database,
            sql: """
            SELECT COALESCE(SUM(length(p.data)), 0) AS bytes
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

    // Returns the role of a message+part row only when it yields a non-empty
    // text part, matching messagePart(from:) so parseSessionInfo counts agree with
    // the streamed transcript.
    private static func contentfulRole(from row: [String: String?]) -> String? {
        guard let rawMessage = row["mdata"] ?? nil,
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
        return role
    }

    private static func messages(from rows: [[String: String?]]) -> [NormalizedMessage] {
        var messages: [NormalizedMessage] = []
        var indexByMessageId: [String: Int] = [:]

        for row in rows {
            guard let part = messagePart(from: row) else { continue }
            if let index = indexByMessageId[part.messageId] {
                messages[index].content += "\n\(part.content)"
            } else {
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
        }

        return messages
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
