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

final class OpenCodeAdapter: SessionAdapter {
    let source: SourceName = .opencode
    private let dbPath: String

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

            var userCount = 0
            var assistantCount = 0
            for message in messages {
                guard let data = (message["data"] ?? nil),
                      let object = Phase4AdapterSupport.jsonObject(from: data),
                      let role = JSONLAdapterSupport.string(object["role"])
                else {
                    continue
                }
                if role == "user" {
                    userCount += 1
                } else if role == "assistant" {
                    assistantCount += 1
                }
            }

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
                    sizeBytes: Phase4AdapterSupport.fileSize(locatorParts.dbPath),
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
                SELECT m.data AS mdata, p.data AS pdata, m.time_created
                FROM message m
                JOIN part p ON p.message_id = m.id
                WHERE m.session_id = ?
                ORDER BY m.time_created ASC, p.time_created ASC
                """,
                bindings: [locatorParts.sessionId]
            )
            let messages = rows.compactMap(Self.message(from:))
            return JSONLAdapterSupport.stream(JSONLAdapterSupport.applyWindow(messages, options: options))
        } catch let failure as ParserFailure {
            throw failure
        } catch {
            throw ParserFailure.sqliteUnreadable
        }
    }

    func isAccessible(locator: String) async -> Bool {
        guard let locatorParts = Self.splitVirtualLocator(locator),
              JSONLAdapterSupport.fileExists(locatorParts.dbPath),
              let database = try? Phase4SQLiteDatabase(path: locatorParts.dbPath)
        else {
            return false
        }
        let rows = try? database.query(
            "SELECT 1 FROM session WHERE id = ? LIMIT 1",
            bindings: [locatorParts.sessionId]
        )
        return rows?.isEmpty == false
    }

    private static func splitVirtualLocator(_ locator: String) -> (dbPath: String, sessionId: String)? {
        guard let range = locator.range(of: "::", options: .backwards) else { return nil }
        return (
            dbPath: String(locator[..<range.lowerBound]),
            sessionId: String(locator[range.upperBound...])
        )
    }

    private static func message(from row: [String: String?]) -> NormalizedMessage? {
        guard let rawMessage = row["mdata"] ?? nil,
              let rawPart = row["pdata"] ?? nil,
              let messageData = Phase4AdapterSupport.jsonObject(from: rawMessage),
              let partData = Phase4AdapterSupport.jsonObject(from: rawPart),
              let role = JSONLAdapterSupport.string(messageData["role"]),
              role == "user" || role == "assistant",
              JSONLAdapterSupport.string(partData["type"]) == "text"
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
        return NormalizedMessage(
            role: role == "user" ? .user : .assistant,
            content: content,
            timestamp: timestamp,
            toolCalls: nil,
            usage: nil
        )
    }
}
