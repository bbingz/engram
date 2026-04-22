import Foundation
import GRDB

final class MCPDatabase {
    private let queue: DatabaseQueue

    init(path: String) throws {
        var configuration = Configuration()
        configuration.readonly = true
        queue = try DatabaseQueue(path: path, configuration: configuration)
    }

    func stats(groupBy: String, since: String?, until: String?) throws -> OrderedJSONValue {
        let groupExpr: String
        switch groupBy {
        case "project":
            groupExpr = "COALESCE(project, '(unknown)')"
        case "day":
            groupExpr = "date(start_time, 'localtime')"
        case "week":
            groupExpr = "date(start_time, 'localtime', 'weekday 0', '-6 days')"
        default:
            groupExpr = "source"
        }

        var conditions = ["hidden_at IS NULL", "orphan_status IS NULL"]
        var arguments: [String: DatabaseValueConvertible?] = [:]
        if let since {
            conditions.append("start_time >= :since")
            arguments["since"] = since
        }
        if let until {
            conditions.append("start_time <= :until")
            arguments["until"] = until
        }

        let sql = """
        SELECT \(groupExpr) AS key,
               COUNT(*) AS sessionCount,
               SUM(message_count) AS messageCount,
               SUM(CASE WHEN tier IS NOT NULL AND tier IN ('skip', 'lite') THEN 0 ELSE user_message_count END) AS userMessageCount,
               SUM(assistant_message_count) AS assistantMessageCount,
               SUM(tool_message_count) AS toolMessageCount
        FROM sessions
        WHERE \(conditions.joined(separator: " AND "))
        GROUP BY \(groupExpr)
        ORDER BY sessionCount DESC
        """

        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
        let groups = rows.map { row in
            OrderedJSONValue.object([
                ("key", .string(row["key"])),
                ("sessionCount", .int(row["sessionCount"])),
                ("messageCount", .int(row["messageCount"])),
                ("userMessageCount", .int(row["userMessageCount"])),
                ("assistantMessageCount", .int(row["assistantMessageCount"])),
                ("toolMessageCount", .int(row["toolMessageCount"])),
            ])
        }
        let totalSessions = rows.reduce(0) { partial, row in
            partial + (row["sessionCount"] as Int)
        }

        return .object([
            ("groupBy", .string(groupBy)),
            ("groups", .array(groups)),
            ("totalSessions", .int(totalSessions)),
        ])
    }

    func listSessions(
        source: String?,
        project: String?,
        since: String?,
        until: String?,
        limit: Int,
        offset: Int
    ) throws -> OrderedJSONValue {
        var conditions = ["hidden_at IS NULL", "orphan_status IS NULL"]
        var values: [DatabaseValueConvertible?] = []
        if let source {
            conditions.append("source = ?")
            values.append(source)
        }
        if let project {
            let projects = try resolveProjectAliases([project])
            if projects.count == 1, let only = projects.first {
                conditions.append("project = ?")
                values.append(only)
            } else if !projects.isEmpty {
                let placeholders = Array(repeating: "?", count: projects.count).joined(separator: ",")
                conditions.append("project IN (\(placeholders))")
                values.append(contentsOf: projects)
            }
        }
        if let since {
            conditions.append("start_time >= ?")
            values.append(since)
        }
        if let until {
            conditions.append("start_time <= ?")
            values.append(until)
        }
        values.append(limit)
        values.append(offset)

        let sql = """
        SELECT base.*, ls.local_readable_path
        FROM (
          SELECT *
          FROM sessions
          WHERE \(conditions.joined(separator: " AND "))
          ORDER BY start_time DESC
          LIMIT ? OFFSET ?
        ) base
        LEFT JOIN session_local_state ls ON ls.session_id = base.id
        ORDER BY base.start_time DESC
        """

        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(values))
        }

        return .object([
            ("sessions", .array(rows.map(listSessionObject(from:)))),
            ("total", .int(rows.count)),
        ])
    }

    func getCosts(groupBy: String, since: String?, until: String?) throws -> OrderedJSONValue {
        let groupExpr: String
        switch groupBy {
        case "source":
            groupExpr = "s.source"
        case "project":
            groupExpr = "s.project"
        case "day":
            groupExpr = "date(s.start_time)"
        default:
            groupExpr = "c.model"
        }

        var sql = """
        SELECT \(groupExpr) AS key,
               SUM(c.input_tokens) AS inputTokens,
               SUM(c.output_tokens) AS outputTokens,
               SUM(c.cache_read_tokens) AS cacheReadTokens,
               SUM(c.cache_creation_tokens) AS cacheCreationTokens,
               SUM(c.cost_usd) AS costUsd,
               COUNT(*) AS sessionCount
        FROM session_costs c
        JOIN sessions s ON c.session_id = s.id
        WHERE 1 = 1
        """
        var arguments: [String: DatabaseValueConvertible?] = [:]
        if let since {
            sql += " AND s.start_time >= :since"
            arguments["since"] = since
        }
        if let until {
            sql += " AND s.start_time < :until"
            arguments["until"] = until
        }
        sql += " GROUP BY \(groupExpr) ORDER BY costUsd DESC"

        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
        let totalCostUsd = rows.reduce(0.0) { partial, row in
            partial + doubleValue(row["costUsd"])
        }
        let totalInputTokens = rows.reduce(0) { partial, row in
            partial + intValue(row["inputTokens"])
        }
        let totalOutputTokens = rows.reduce(0) { partial, row in
            partial + intValue(row["outputTokens"])
        }

        return .object([
            ("totalCostUsd", .double((totalCostUsd * 100).rounded() / 100)),
            ("totalInputTokens", .int(totalInputTokens)),
            ("totalOutputTokens", .int(totalOutputTokens)),
            ("breakdown", .array(rows.map(costSummaryObject(from:)))),
        ])
    }

    func getToolAnalytics(project: String?, since: String?, groupBy: String) throws -> OrderedJSONValue {
        let selectColumns: String
        let groupExpr: String
        switch groupBy {
        case "session":
            selectColumns = """
            t.session_id AS key,
            s.summary AS label,
            SUM(t.call_count) AS callCount,
            COUNT(DISTINCT t.tool_name) AS toolCount
            """
            groupExpr = "t.session_id"
        case "project":
            selectColumns = """
            s.project AS key,
            SUM(t.call_count) AS callCount,
            COUNT(DISTINCT t.tool_name) AS toolCount,
            COUNT(DISTINCT t.session_id) AS sessionCount
            """
            groupExpr = "s.project"
        default:
            selectColumns = """
            t.tool_name AS key,
            SUM(t.call_count) AS callCount,
            COUNT(DISTINCT t.session_id) AS sessionCount
            """
            groupExpr = "t.tool_name"
        }

        var sql = """
        SELECT \(selectColumns)
        FROM session_tools t
        JOIN sessions s ON t.session_id = s.id
        WHERE 1 = 1
        """
        var arguments: [String: DatabaseValueConvertible?] = [:]
        if let project {
            sql += " AND s.project LIKE :project ESCAPE '\\\\'"
            arguments["project"] = "%\(escapeLike(project))%"
        }
        if let since {
            sql += " AND s.start_time >= :since"
            arguments["since"] = since
        }
        sql += " GROUP BY \(groupExpr) ORDER BY callCount DESC"

        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
        let totalCalls = rows.reduce(0) { partial, row in
            partial + intValue(row["callCount"])
        }

        return .object([
            ("tools", .array(rows.map { toolAnalyticsObject(from: $0, groupBy: groupBy) })),
            ("totalCalls", .int(totalCalls)),
            ("groupCount", .int(rows.count)),
        ])
    }

    func getFileActivity(project: String?, since: String?, limit: Int) throws -> OrderedJSONValue {
        var conditions: [String] = []
        var arguments: [String: DatabaseValueConvertible?] = [:]
        if let project {
            conditions.append("s.project = :project")
            arguments["project"] = project
        }
        if let since {
            conditions.append("s.start_time >= :since")
            arguments["since"] = since
        }
        arguments["limit"] = limit

        let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        let sql = """
        SELECT sf.file_path, sf.action,
               SUM(sf.count) AS total_count,
               COUNT(DISTINCT sf.session_id) AS session_count
        FROM session_files sf
        JOIN sessions s ON s.id = sf.session_id
        \(whereClause)
        GROUP BY sf.file_path, sf.action
        ORDER BY total_count DESC
        LIMIT :limit
        """
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }

        return .object([
            ("files", .array(rows.map { row in
                .object([
                    ("file_path", .string(row["file_path"])),
                    ("action", .string(row["action"])),
                    ("total_count", .int(row["total_count"])),
                    ("session_count", .int(row["session_count"])),
                ])
            })),
            ("totalFiles", .int(rows.count)),
        ])
    }

    func projectTimeline(project: String, since: String?, until: String?) throws -> OrderedJSONValue {
        var conditions = [
            "hidden_at IS NULL",
            "orphan_status IS NULL",
        ]
        var values: [DatabaseValueConvertible?] = []
        let projects = try resolveProjectAliases([project])
        if projects.count == 1, let only = projects.first {
            conditions.append("project = ?")
            values.append(only)
        } else if !projects.isEmpty {
            let placeholders = Array(repeating: "?", count: projects.count).joined(separator: ",")
            conditions.append("project IN (\(placeholders))")
            values.append(contentsOf: projects)
        }
        if let since {
            conditions.append("start_time >= ?")
            values.append(since)
        }
        if let until {
            conditions.append("start_time <= ?")
            values.append(until)
        }
        values.append(200)

        let sql = """
        SELECT id, source, start_time, summary, message_count
        FROM sessions
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY start_time DESC
        LIMIT ?
        """
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(values))
        }
        let timeline = rows
            .map { row in
                OrderedJSONValue.object([
                    ("time", .string(toLocalDateTime(stringValue(row["start_time"])))),
                    ("source", .string(row["source"])),
                    ("summary", .string(stringValue(row["summary"]) ?? "（无摘要）")),
                    ("sessionId", .string(row["id"])),
                    ("messageCount", .int(row["message_count"])),
                ])
            }
            .sorted { lhs, rhs in
                guard case .object(let leftEntries) = lhs,
                      case .object(let rightEntries) = rhs,
                      let leftTime = leftEntries.first(where: { $0.0 == "time" })?.1.stringLiteral,
                      let rightTime = rightEntries.first(where: { $0.0 == "time" })?.1.stringLiteral else {
                    return false
                }
                return leftTime < rightTime
            }

        return .object([
            ("project", .string(project)),
            ("timeline", .array(timeline)),
            ("total", .int(timeline.count)),
        ])
    }

    func listMigrations(limit: Int, since: String?) throws -> OrderedJSONValue {
        var conditions: [String] = []
        var arguments: [String: DatabaseValueConvertible?] = [:]
        if let since {
            conditions.append("started_at >= :since")
            arguments["since"] = since
        }
        arguments["limit"] = min(max(limit, 1), 200)
        arguments["offset"] = 0

        let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        let sql = """
        SELECT *
        FROM migration_log
        \(whereClause)
        ORDER BY started_at DESC, rowid DESC
        LIMIT :limit OFFSET :offset
        """
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
        return .array(rows.map(migrationObject(from:)))
    }

    func getMemory(query: String) throws -> OrderedJSONValue {
        if let matches = try? searchInsightsFTS(query: query, limit: 10), !matches.isEmpty {
            return .object([
                ("memories", .array(matches.map { memoryObject(from: $0, distance: 0) })),
                ("warning", .string("No embedding provider — showing keyword-matched insights only.")),
            ])
        }

        let recent = try listInsightsByWing(wing: nil, limit: 10)
        if !recent.isEmpty {
            return .object([
                ("memories", .array(recent.map { memoryObject(from: $0, distance: 0) })),
                ("warning", .string("No embedding provider — showing recent insights only.")),
            ])
        }

        return .object([
            ("memories", .array([])),
            ("message", .string("No memories found. Use save_insight to add knowledge that persists across sessions.")),
        ])
    }

    func listProjectAliases() throws -> OrderedJSONValue {
        let rows = try queue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT alias, canonical FROM project_aliases ORDER BY canonical, alias"
            )
        }
        return .array(rows.map { row in
            .object([
                ("alias", .string(row["alias"])),
                ("canonical", .string(row["canonical"])),
            ])
        })
    }

    private func searchInsightsFTS(query: String, limit: Int) throws -> [Row] {
        if containsCJK(query) {
            return try queue.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM insights WHERE content LIKE :pattern ORDER BY created_at DESC LIMIT :limit",
                    arguments: ["pattern": "%\(query)%", "limit": limit]
                )
            }
        }

        func runQuery(_ candidate: String) throws -> [Row] {
            try queue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT i.*
                    FROM insights_fts f
                    JOIN insights i ON i.id = f.insight_id
                    WHERE insights_fts MATCH :query
                    ORDER BY f.rank
                    LIMIT :limit
                    """,
                    arguments: ["query": candidate, "limit": limit]
                )
            }
        }

        do {
            return try runQuery(query)
        } catch {
            let escaped = "\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""
            return try runQuery(escaped)
        }
    }

    private func listInsightsByWing(wing: String?, limit: Int) throws -> [Row] {
        try queue.read { db in
            if let wing {
                return try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM insights WHERE wing = :wing ORDER BY created_at DESC LIMIT :limit",
                    arguments: ["wing": wing, "limit": limit]
                )
            }
            return try Row.fetchAll(
                db,
                sql: "SELECT * FROM insights ORDER BY created_at DESC LIMIT :limit",
                arguments: ["limit": limit]
            )
        }
    }

    private func resolveProjectAliases(_ projects: [String]) throws -> [String] {
        guard !projects.isEmpty else { return projects }
        return try queue.read { db in
            let placeholders = Array(repeating: "?", count: projects.count).joined(separator: ",")

            let sql = """
            SELECT DISTINCT alias AS name FROM project_aliases WHERE canonical IN (\(placeholders))
            UNION
            SELECT DISTINCT canonical AS name FROM project_aliases WHERE alias IN (\(placeholders))
            """
            let positional: [DatabaseValueConvertible?] = projects + projects
            let rows = try Row.fetchAll(
                db,
                sql: sql,
                arguments: StatementArguments(positional)
            )
            var all = Set(projects)
            for row in rows {
                all.insert(stringValue(row["name"]) ?? "")
            }
            return all.filter { !$0.isEmpty }
        }
    }
}

private func listSessionObject(from row: Row) -> OrderedJSONValue {
    let startTime = toLocalDateTime(stringValue(row["start_time"]))
    let endTime = toLocalDateTime(stringValue(row["end_time"]))
    let entries: [(String, OrderedJSONValue)] = [
        ("id", .string(row["id"])),
        ("source", .string(row["source"])),
        ("startTime", .string(startTime)),
        ("endTime", .string(endTime)),
        ("cwd", .string(row["cwd"])),
        ("project", valueOrNull(stringValue(row["project"]))),
        ("model", valueOrNull(stringValue(row["model"]))),
        ("messageCount", .int(row["message_count"])),
        ("userMessageCount", .int(row["user_message_count"])),
        ("summary", valueOrNull(stringValue(row["summary"]))),
    ]
    return .object(entries)
}

private func costSummaryObject(from row: Row) -> OrderedJSONValue {
    let entries: [(String, OrderedJSONValue)] = [
        ("key", valueOrNull(stringValue(row["key"]))),
        ("inputTokens", .int(row["inputTokens"])),
        ("outputTokens", .int(row["outputTokens"])),
        ("cacheReadTokens", .int(row["cacheReadTokens"])),
        ("cacheCreationTokens", .int(row["cacheCreationTokens"])),
        ("costUsd", .double(doubleValue(row["costUsd"]))),
        ("sessionCount", .int(row["sessionCount"])),
    ]
    return .object(entries)
}

private func toolAnalyticsObject(from row: Row, groupBy: String) -> OrderedJSONValue {
    var entries: [(String, OrderedJSONValue)] = [
        ("key", valueOrNull(stringValue(row["key"]))),
        ("callCount", .int(row["callCount"])),
    ]
    if groupBy == "session" {
        entries.append(("label", valueOrNull(stringValue(row["label"]))))
        entries.append(("toolCount", .int(intValue(row["toolCount"]))))
    } else if groupBy == "project" {
        entries.append(("toolCount", .int(intValue(row["toolCount"]))))
        entries.append(("sessionCount", .int(intValue(row["sessionCount"]))))
    } else {
        entries.append(("sessionCount", .int(intValue(row["sessionCount"]))))
    }
    return .object(entries)
}

private func migrationObject(from row: Row) -> OrderedJSONValue {
    let entries: [(String, OrderedJSONValue)] = [
        ("id", .string(row["id"])),
        ("oldPath", .string(row["old_path"])),
        ("newPath", .string(row["new_path"])),
        ("oldBasename", .string(row["old_basename"])),
        ("newBasename", .string(row["new_basename"])),
        ("state", .string(row["state"])),
        ("filesPatched", .int(row["files_patched"])),
        ("occurrences", .int(row["occurrences"])),
        ("sessionsUpdated", .int(row["sessions_updated"])),
        ("aliasCreated", .bool(boolValue(row["alias_created"]))),
        ("ccDirRenamed", .bool(boolValue(row["cc_dir_renamed"]))),
        ("startedAt", .string(row["started_at"])),
        ("finishedAt", valueOrNull(stringValue(row["finished_at"]))),
        ("dryRun", .bool(boolValue(row["dry_run"]))),
        ("rolledBackOf", valueOrNull(stringValue(row["rolled_back_of"]))),
        ("auditNote", valueOrNull(stringValue(row["audit_note"]))),
        ("archived", .bool(boolValue(row["archived"]))),
        ("actor", .string(row["actor"])),
        ("detail", detailJSONValue(from: row["detail"])),
        ("error", valueOrNull(stringValue(row["error"]))),
    ]
    return .object(entries)
}

private func memoryObject(from row: Row, distance: Double) -> OrderedJSONValue {
    .object([
        ("id", .string(row["id"])),
        ("content", .string(row["content"])),
        ("wing", valueOrNull(stringValue(row["wing"]))),
        ("room", valueOrNull(stringValue(row["room"]))),
        ("importance", .int(row["importance"])),
        ("distance", .double(distance)),
    ])
}

private func detailJSONValue(from raw: DatabaseValueConvertible?) -> OrderedJSONValue {
    guard let text = raw as? String else {
        return .null
    }
    var parser = OrderedJSONStringParser(text: text)
    return (try? parser.parse()) ?? .null
}

private func containsCJK(_ text: String) -> Bool {
    text.range(of: #"[\u{2E80}-\u{9FFF}\u{F900}-\u{FAFF}\u{FE30}-\u{FE4F}]"#, options: .regularExpression) != nil
}

private func escapeLike(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "%", with: "\\%")
        .replacingOccurrences(of: "_", with: "\\_")
}

private func valueOrNull(_ value: String?) -> OrderedJSONValue {
    guard let value else { return .null }
    return .string(value)
}

private func intValue(_ value: DatabaseValueConvertible?) -> Int {
    switch value {
    case let value as Int:
        return value
    case let value as Int64:
        return Int(value)
    case let value as Double:
        return Int(value)
    default:
        return 0
    }
}

private func doubleValue(_ value: DatabaseValueConvertible?) -> Double {
    switch value {
    case let value as Double:
        return value
    case let value as Int:
        return Double(value)
    case let value as Int64:
        return Double(value)
    default:
        return 0
    }
}

private func boolValue(_ value: DatabaseValueConvertible?) -> Bool {
    switch value {
    case let value as Bool:
        return value
    case let value as Int:
        return value != 0
    case let value as Int64:
        return value != 0
    default:
        return false
    }
}

private func stringValue(_ value: DatabaseValueConvertible?) -> String? {
    switch value {
    case let value as String:
        return value
    case let value as NSString:
        return value as String
    default:
        return nil
    }
}

private func toLocalDateTime(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "" }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let fallback = ISO8601DateFormatter()
    guard let date = formatter.date(from: value) ?? fallback.date(from: value) else {
        return value
    }

    let output = DateFormatter()
    output.locale = Locale(identifier: "sv_SE")
    if let configured = ProcessInfo.processInfo.environment["TZ"],
       let timeZone = TimeZone(identifier: configured) {
        output.timeZone = timeZone
    } else {
        output.timeZone = .autoupdatingCurrent
    }
    output.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return output.string(from: date)
}

private extension OrderedJSONValue {
    var stringLiteral: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

private struct OrderedJSONStringParser {
    let text: String
    private var index: String.Index

    init(text: String) {
        self.text = text
        self.index = text.startIndex
    }

    mutating func parse() throws -> OrderedJSONValue {
        let value = try parseValue()
        skipWhitespace()
        return value
    }

    private mutating func parseValue() throws -> OrderedJSONValue {
        skipWhitespace()
        guard index < text.endIndex else { throw ParserError.unexpectedEOF }
        switch text[index] {
        case "{":
            return try parseObject()
        case "[":
            return try parseArray()
        case "\"":
            return .string(try parseString())
        case "t":
            try consume("true")
            return .bool(true)
        case "f":
            try consume("false")
            return .bool(false)
        case "n":
            try consume("null")
            return .null
        default:
            return try parseNumber()
        }
    }

    private mutating func parseObject() throws -> OrderedJSONValue {
        advance()
        skipWhitespace()
        var entries: [(String, OrderedJSONValue)] = []
        if current == "}" {
            advance()
            return .object(entries)
        }
        while true {
            let key = try parseString()
            skipWhitespace()
            try expect(":")
            let value = try parseValue()
            entries.append((key, value))
            skipWhitespace()
            if current == "}" {
                advance()
                return .object(entries)
            }
            try expect(",")
        }
    }

    private mutating func parseArray() throws -> OrderedJSONValue {
        advance()
        skipWhitespace()
        var values: [OrderedJSONValue] = []
        if current == "]" {
            advance()
            return .array(values)
        }
        while true {
            values.append(try parseValue())
            skipWhitespace()
            if current == "]" {
                advance()
                return .array(values)
            }
            try expect(",")
        }
    }

    private mutating func parseString() throws -> String {
        try expect("\"")
        var result = ""
        while index < text.endIndex {
            let character = text[index]
            advance()
            if character == "\"" {
                return result
            }
            if character == "\\" {
                guard index < text.endIndex else { throw ParserError.unexpectedEOF }
                let escaped = text[index]
                advance()
                switch escaped {
                case "\"", "\\", "/":
                    result.append(escaped)
                case "b":
                    result.append("\u{8}")
                case "f":
                    result.append("\u{c}")
                case "n":
                    result.append("\n")
                case "r":
                    result.append("\r")
                case "t":
                    result.append("\t")
                case "u":
                    let hex = try read(length: 4)
                    guard let scalar = UInt32(hex, radix: 16).flatMap(UnicodeScalar.init) else {
                        throw ParserError.invalidEscape
                    }
                    result.unicodeScalars.append(scalar)
                default:
                    throw ParserError.invalidEscape
                }
            } else {
                result.append(character)
            }
        }
        throw ParserError.unexpectedEOF
    }

    private mutating func parseNumber() throws -> OrderedJSONValue {
        let start = index
        while index < text.endIndex, "-+0123456789.eE".contains(text[index]) {
            advance()
        }
        let raw = String(text[start..<index])
        if raw.contains(".") || raw.contains("e") || raw.contains("E") {
            guard let value = Double(raw) else { throw ParserError.invalidNumber }
            return .double(value)
        }
        guard let value = Int(raw) else { throw ParserError.invalidNumber }
        return .int(value)
    }

    private mutating func expect(_ token: Character) throws {
        skipWhitespace()
        guard current == token else { throw ParserError.unexpectedToken }
        advance()
    }

    private mutating func consume(_ token: String) throws {
        for character in token {
            guard current == character else { throw ParserError.unexpectedToken }
            advance()
        }
    }

    private mutating func read(length: Int) throws -> String {
        guard text.distance(from: index, to: text.endIndex) >= length else {
            throw ParserError.unexpectedEOF
        }
        let end = text.index(index, offsetBy: length)
        let value = String(text[index..<end])
        index = end
        return value
    }

    private mutating func skipWhitespace() {
        while index < text.endIndex, text[index].isWhitespace {
            advance()
        }
    }

    private mutating func advance() {
        index = text.index(after: index)
    }

    private var current: Character? {
        index < text.endIndex ? text[index] : nil
    }

    private enum ParserError: Error {
        case unexpectedEOF
        case unexpectedToken
        case invalidEscape
        case invalidNumber
    }
}
