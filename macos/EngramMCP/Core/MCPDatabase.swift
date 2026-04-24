import Foundation
import GRDB

struct MCPSessionRecord {
    let id: String
    let source: String
    let startTime: String
    let endTime: String?
    let cwd: String
    let project: String?
    let model: String?
    let messageCount: Int
    let userMessageCount: Int
    let assistantMessageCount: Int
    let toolMessageCount: Int
    let systemMessageCount: Int
    let summary: String?
    let filePath: String
    let sizeBytes: Int
    let indexedAt: String?
    let agentRole: String?
    let origin: String?
    let summaryMessageCount: Int?
    let tier: String?
    let qualityScore: Int?
    let parentSessionId: String?
    let suggestedParentId: String?

    var orderedJSONValue: OrderedJSONValue {
        .object([
            ("id", .string(id)),
            ("source", .string(source)),
            ("startTime", .string(startTime)),
            ("endTime", valueOrNull(endTime)),
            ("cwd", .string(cwd)),
            ("project", valueOrNull(project)),
            ("model", valueOrNull(model)),
            ("messageCount", .int(messageCount)),
            ("userMessageCount", .int(userMessageCount)),
            ("assistantMessageCount", .int(assistantMessageCount)),
            ("toolMessageCount", .int(toolMessageCount)),
            ("systemMessageCount", .int(systemMessageCount)),
            ("summary", valueOrNull(summary)),
            ("filePath", .string(filePath)),
            ("sizeBytes", .int(sizeBytes)),
            ("indexedAt", valueOrNull(indexedAt)),
            ("agentRole", valueOrNull(agentRole)),
            ("origin", valueOrNull(origin)),
            ("summaryMessageCount", summaryMessageCount.map(OrderedJSONValue.int) ?? .null),
            ("tier", valueOrNull(tier)),
            ("qualityScore", qualityScore.map(OrderedJSONValue.int) ?? .null),
            ("parentSessionId", valueOrNull(parentSessionId)),
            ("suggestedParentId", valueOrNull(suggestedParentId)),
        ])
    }
}

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

    func projectRecover(since: String?, includeCommitted: Bool) throws -> OrderedJSONValue {
        var conditions: [String] = []
        var arguments: [String: DatabaseValueConvertible?] = [:]
        let states = includeCommitted
            ? ["fs_pending", "fs_done", "failed", "committed"]
            : ["fs_pending", "fs_done", "failed"]
        let placeholders = states.enumerated().map { index, _ in ":state\(index)" }.joined(separator: ", ")
        for (index, state) in states.enumerated() {
            arguments["state\(index)"] = state
        }
        conditions.append("state IN (\(placeholders))")
        if let since {
            conditions.append("started_at >= :since")
            arguments["since"] = since
        }

        let sql = """
        SELECT *
        FROM migration_log
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY started_at DESC, rowid DESC
        """
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }

        let diagnoses = rows.map { row in
            let oldPath = stringValue(row["old_path"]) ?? ""
            let newPath = stringValue(row["new_path"]) ?? ""
            let oldState = probePathState(oldPath)
            let newState = probePathState(newPath)
            let artifacts = scanTempArtifacts(oldPath: oldPath, newPath: newPath)

            return OrderedJSONValue.object([
                ("migrationId", .string(stringValue(row["id"]) ?? "")),
                ("state", .string(stringValue(row["state"]) ?? "")),
                ("oldPath", .string(oldPath)),
                ("newPath", .string(newPath)),
                ("startedAt", .string(stringValue(row["started_at"]) ?? "")),
                ("finishedAt", valueOrNull(stringValue(row["finished_at"]))),
                ("error", valueOrNull(stringValue(row["error"]))),
                ("fs", .object([
                    ("oldPathExists", .bool(oldState == "exists")),
                    ("newPathExists", .bool(newState == "exists")),
                    ("oldPathState", .string(oldState)),
                    ("newPathState", .string(newState)),
                    ("tempArtifacts", .array(artifacts.paths.map(OrderedJSONValue.string))),
                    ("probeError", valueOrNull(artifacts.error)),
                ])),
                ("recommendation", .string(buildRecoverRecommendation(
                    state: stringValue(row["state"]) ?? "",
                    oldExists: oldState == "exists",
                    newExists: newState == "exists"
                ))),
            ])
        }

        return .array(diagnoses)
    }

    func searchSessions(
        query: String,
        source: String?,
        project: String?,
        since: String?,
        limit: Int,
        mode: String
    ) throws -> OrderedJSONValue {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cappedLimit = min(max(limit, 1), 50)
        let normalizedMode = mode.isEmpty ? "hybrid" : mode

        if isUUID(normalizedQuery) {
            if let row = try fetchSessionRow(id: normalizedQuery) {
                return .object([
                    ("results", .array([
                        .object([
                            ("session", fullSessionObject(from: row)),
                            ("snippet", .string("")),
                            ("matchType", .string("keyword")),
                            ("score", .double(1)),
                        ]),
                    ])),
                    ("query", .string(query)),
                    ("searchModes", .array([.string("id")])),
                ])
            }

            return .object([
                ("results", .array([])),
                ("query", .string(query)),
                ("searchModes", .array([.string("id")])),
                ("warning", .string("No session found with this ID")),
            ])
        }

        guard normalizedMode != "semantic", normalizedQuery.count >= 3 else {
            var entries: [(String, OrderedJSONValue)] = [
                ("results", .array([])),
                ("query", .string(query)),
                ("searchModes", .array([])),
            ]
            if normalizedQuery.count < 3 {
                entries.append(("warning", .string("Search query needs at least 3 characters for keyword search (2 for semantic)")))
            }
            return .object(entries)
        }

        let matches = try keywordSearch(
            query: normalizedQuery,
            source: source,
            project: project,
            since: since,
            limit: cappedLimit * 3
        )

        var seen = Set<String>()
        var ranked: [(sessionID: String, snippet: String, score: Double)] = []
        var rank = 1
        for match in matches {
            guard seen.insert(match.sessionID).inserted else { continue }
            ranked.append((match.sessionID, match.snippet, 1.0 / Double(60 + rank)))
            rank += 1
            if ranked.count >= cappedLimit { break }
        }

        let resultRows = try ranked.compactMap { match -> OrderedJSONValue? in
            guard let row = try fetchSessionRow(id: match.sessionID) else { return nil }
            return .object([
                ("session", fullSessionObject(from: row)),
                ("snippet", .string(match.snippet.isEmpty ? (stringValue(row["summary"]) ?? "") : match.snippet)),
                ("matchType", .string("keyword")),
                ("score", .double(match.score)),
            ])
        }

        var entries: [(String, OrderedJSONValue)] = [
            ("results", .array(resultRows)),
            ("query", .string(query)),
            ("searchModes", .array([.string("keyword")])),
        ]

        if normalizedQuery.count >= 3 {
            let insightRows = try searchInsightsFTS(query: normalizedQuery, limit: 5)
            let insightResults = insightRows.compactMap { row -> OrderedJSONValue? in
                guard let content = stringValue(row["content"]), !content.isEmpty else { return nil }
                return .string(content)
            }
            if !insightResults.isEmpty {
                entries.append(("insightResults", .array(insightResults)))
            }
        }

        if normalizedMode == "semantic" || normalizedMode == "hybrid" {
            entries.append(("warning", .string("Embedding provider unavailable — results are keyword-only (FTS).")))
        }

        return .object(entries)
    }

    func getContext(
        cwd: String,
        task: String?,
        maxTokens: Int,
        detail: String,
        sortBy: String,
        includeEnvironment: Bool
    ) throws -> String {
        let maxChars = maxTokens * 4
        let projectName = URL(fileURLWithPath: cwd).lastPathComponent
        var sessions = try listContextSessions(projectName: projectName, cwd: cwd)

        if sortBy == "score" {
            sessions.sort { intValue($0["quality_score"]) > intValue($1["quality_score"]) }
        } else {
            sessions.sort { (stringValue($0["start_time"]) ?? "") > (stringValue($1["start_time"]) ?? "") }
        }

        var parts: [String] = []
        var totalChars = 0
        var selectedCount = 0
        var memoryCount = 0

        if let task, !task.isEmpty {
            let line = "当前任务：\(task)\n"
            parts.append(line)
            totalChars += line.count
        }

        if let task, task.count >= 3 {
            let insightRows = try searchInsightsFTS(query: task, limit: 5)
            for row in insightRows {
                guard let content = stringValue(row["content"]), !content.isEmpty else { continue }
                let line = "[memory] \(content)\n"
                if totalChars + line.count > maxChars { break }
                parts.append(line)
                totalChars += line.count
                memoryCount += 1
            }
        }

        for row in sessions {
            guard let summary = stringValue(row["summary"]), !summary.isEmpty else { continue }
            let source = stringValue(row["source"]) ?? "unknown"
            let date = toLocalDate(stringValue(row["start_time"]))
            let line = "[\(source)] \(date) — \(summary)\n"
            if totalChars + line.count > maxChars { break }
            parts.append(line)
            totalChars += line.count
            selectedCount += 1
        }

        let memoryNote = memoryCount > 0 ? " + \(memoryCount) memories" : ""
        let footer = "\n— \(selectedCount) sessions\(memoryNote), ~\(Int(ceil(Double(totalChars) / 4.0))) tokens"
        parts.append(footer)

        if includeEnvironment {
            parts.append(try contextEnvironmentSection(detail: detail, maxTokens: maxTokens))
        }

        return parts.joined()
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

    func resolvedProjectAliases(for project: String) throws -> [String] {
        try resolveProjectAliases([project])
    }

    func totalCostSince(_ since: String) throws -> Double {
        try queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT SUM(c.cost_usd) AS cost
                FROM session_costs c
                JOIN sessions s ON c.session_id = s.id
                WHERE s.start_time >= ?
                """,
                arguments: [since]
            )
            return doubleValue(row?["cost"])
        }
    }

    private func contextEnvironmentSection(detail: String, maxTokens: Int) throws -> String {
        let normalizedDetail: String
        switch detail {
        case "abstract", "overview", "full":
            normalizedDetail = detail
        default:
            normalizedDetail = "full"
        }

        let now = contextNow()
        let calendar = Calendar(identifier: .gregorian)
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let startOfSevenDayWindow = calendar.date(byAdding: .day, value: -7, to: now) ?? now

        var sections: [String] = []
        let todayCost = try totalCostBetween(
            start: iso8601Timestamp(startOfToday),
            end: iso8601Timestamp(startOfTomorrow)
        )
        if todayCost > 0 {
            sections.append(String(format: "Cost today: $%.2f", locale: Locale(identifier: "en_US_POSIX"), todayCost))
        }

        if normalizedDetail != "abstract" {
            let toolLimit = normalizedDetail == "overview" ? 5 : 10
            let topTools = try topToolsSince(iso8601Timestamp(startOfSevenDayWindow), limit: toolLimit)
            if !topTools.isEmpty {
                let lines = topTools.map { "  \($0.name): \($0.callCount) calls" }.joined(separator: "\n")
                sections.append("Top tools (7d):\n\(lines)")
            }
        }

        let maxEnvChars = Double(maxTokens * 4) * 0.3
        if normalizedDetail == "full", sections.joined(separator: "\n").count > Int(maxEnvChars) {
            sections.removeAll { $0.hasPrefix("Top tools (7d):") }
        }

        guard !sections.isEmpty else { return "" }
        return "\n\n## Environment\n" + sections.joined(separator: "\n")
    }

    func sessionRecord(id: String) throws -> MCPSessionRecord? {
        guard let row = try fetchSessionRow(id: id) else { return nil }
        return makeSessionRecord(from: row)
    }

    private func totalCostBetween(start: String, end: String) throws -> Double {
        try queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT SUM(cost_usd) AS cost
                FROM session_costs
                WHERE computed_at >= ? AND computed_at < ?
                """,
                arguments: [start, end]
            )
            return doubleValue(row?["cost"])
        }
    }

    private func topToolsSince(_ since: String, limit: Int) throws -> [(name: String, callCount: Int)] {
        try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT t.tool_name AS name, SUM(t.call_count) AS call_count
                FROM session_tools t
                JOIN sessions s ON s.id = t.session_id
                WHERE s.start_time >= ?
                GROUP BY t.tool_name
                ORDER BY call_count DESC, name ASC
                LIMIT ?
                """,
                arguments: [since, limit]
            )
            return rows.compactMap { row in
                guard let name = stringValue(row["name"]), !name.isEmpty else { return nil }
                return (name, intValue(row["call_count"]))
            }
        }
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

    private func fetchSessionRow(id: String) throws -> Row? {
        try queue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT s.*, ls.local_readable_path
                FROM sessions s
                LEFT JOIN session_local_state ls ON ls.session_id = s.id
                WHERE s.id = ?
                LIMIT 1
                """,
                arguments: [id]
            )
        }
    }

    private func listContextSessions(projectName: String, cwd: String) throws -> [Row] {
        let projects = try resolveProjectAliases([projectName])
        return try queue.read { db in
            if !projects.isEmpty {
                let placeholders = Array(repeating: "?", count: projects.count).joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT s.*
                    FROM sessions s
                    WHERE s.hidden_at IS NULL
                      AND s.orphan_status IS NULL
                      AND s.project IN (\(placeholders))
                    ORDER BY s.start_time DESC
                    LIMIT 50
                    """,
                    arguments: StatementArguments(projects)
                )
                if !rows.isEmpty { return rows }
            }

            return try Row.fetchAll(
                db,
                sql: """
                SELECT s.*
                FROM sessions s
                WHERE s.hidden_at IS NULL
                  AND s.orphan_status IS NULL
                  AND s.project = ?
                ORDER BY s.start_time DESC
                LIMIT 50
                """,
                arguments: [cwd]
            )
        }
    }

    private func keywordSearch(
        query: String,
        source: String?,
        project: String?,
        since: String?,
        limit: Int
    ) throws -> [(sessionID: String, snippet: String)] {
        let expandedProjects = try project.map { try resolveProjectAliases([$0]) } ?? []
        return try queue.read { db in
            var conditions = [
                "sessions_fts MATCH ?",
                "s.hidden_at IS NULL",
                "s.orphan_status IS NULL",
            ]
            var values: [DatabaseValueConvertible?] = [query]

            if let source {
                conditions.append("s.source = ?")
                values.append(source)
            }
            if !expandedProjects.isEmpty {
                if expandedProjects.count == 1, let only = expandedProjects.first {
                    conditions.append("s.project LIKE ?")
                    values.append("%\(only)%")
                } else {
                    let clauses = expandedProjects.map { _ in "s.project LIKE ?" }.joined(separator: " OR ")
                    conditions.append("(\(clauses))")
                    values.append(contentsOf: expandedProjects.map { "%\($0)%" })
                }
            }
            if let since {
                conditions.append("s.start_time >= ?")
                values.append(since)
            }
            values.append(limit)

            let sql = """
            SELECT
              f.session_id AS session_id,
              snippet(sessions_fts, 1, '<mark>', '</mark>', '…', 32) AS snippet,
              f.rank
            FROM sessions_fts f
            JOIN sessions s ON s.id = f.session_id
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY f.rank
            LIMIT ?
            """

            do {
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(values))
                return rows.map { (stringValue($0["session_id"]) ?? "", stringValue($0["snippet"]) ?? "") }
            } catch {
                values[0] = "\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(values))
                return rows.map { (stringValue($0["session_id"]) ?? "", stringValue($0["snippet"]) ?? "") }
            }
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
            return all.filter { !$0.isEmpty }.sorted()
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

private func fullSessionObject(from row: Row) -> OrderedJSONValue {
    makeSessionRecord(from: row).orderedJSONValue
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

private func makeSessionRecord(from row: Row) -> MCPSessionRecord {
    MCPSessionRecord(
        id: stringValue(row["id"]) ?? "",
        source: stringValue(row["source"]) ?? "unknown",
        startTime: stringValue(row["start_time"]) ?? "",
        endTime: stringValue(row["end_time"]),
        cwd: stringValue(row["cwd"]) ?? "",
        project: stringValue(row["project"]),
        model: stringValue(row["model"]),
        messageCount: intValue(row["message_count"]),
        userMessageCount: intValue(row["user_message_count"]),
        assistantMessageCount: intValue(row["assistant_message_count"]),
        toolMessageCount: intValue(row["tool_message_count"]),
        systemMessageCount: intValue(row["system_message_count"]),
        summary: stringValue(row["summary"]),
        filePath: stringValue(row["local_readable_path"]) ?? stringValue(row["file_path"]) ?? "",
        sizeBytes: intValue(row["size_bytes"]),
        indexedAt: stringValue(row["indexed_at"]),
        agentRole: stringValue(row["agent_role"]),
        origin: stringValue(row["origin"]),
        summaryMessageCount: optionalInt(row["summary_message_count"]),
        tier: stringValue(row["tier"]),
        qualityScore: optionalInt(row["quality_score"]),
        parentSessionId: stringValue(row["parent_session_id"]),
        suggestedParentId: stringValue(row["suggested_parent_id"])
    )
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

private func intOrNull(_ value: DatabaseValueConvertible?) -> OrderedJSONValue {
    switch value {
    case let value as Int:
        return .int(value)
    case let value as Int64:
        return .int(Int(value))
    case let value as Double:
        return .int(Int(value))
    default:
        return .null
    }
}

private func optionalInt(_ value: DatabaseValueConvertible?) -> Int? {
    switch value {
    case let value as Int:
        return value
    case let value as Int64:
        return Int(value)
    case let value as Double:
        return Int(value)
    default:
        return nil
    }
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

private func contextNow() -> Date {
    if let raw = ProcessInfo.processInfo.environment["ENGRAM_MCP_NOW"] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) ?? fallback.date(from: raw) {
            return date
        }
    }
    return Date()
}

private func iso8601Timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

func toLocalDateTime(_ value: String?) -> String {
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

func toLocalDate(_ value: String?) -> String {
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
    output.dateFormat = "yyyy-MM-dd"
    return output.string(from: date)
}

private func isUUID(_ value: String) -> Bool {
    value.range(
        of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
        options: .regularExpression
    ) != nil
}

private func probePathState(_ path: String) -> String {
    do {
        _ = try FileManager.default.attributesOfItem(atPath: path)
        return "exists"
    } catch let error as NSError {
        if error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return "absent"
        }
        return "unknown"
    }
}

private func scanTempArtifacts(
    oldPath: String,
    newPath: String
) -> (paths: [String], error: String?) {
    let candidateParents = [
        URL(fileURLWithPath: oldPath).deletingLastPathComponent().path,
        URL(fileURLWithPath: newPath).deletingLastPathComponent().path,
    ]
    var parents: [String] = []
    for parent in candidateParents where !parent.isEmpty && parent != "/" && parent != "." {
        if !parents.contains(parent) {
            parents.append(parent)
        }
    }

    var found: [String] = []
    var errors: [String] = []
    let oldBase = URL(fileURLWithPath: oldPath).lastPathComponent
    let newBase = URL(fileURLWithPath: newPath).lastPathComponent

    for parent in parents {
        do {
            let entries = try FileManager.default.contentsOfDirectory(atPath: parent)
            for name in entries {
                if name.hasPrefix(".engram-tmp-") ||
                    name.hasPrefix(".engram-move-tmp-") ||
                    name.hasPrefix("\(newBase).engram-move-tmp-") ||
                    name.hasPrefix("\(oldBase).engram-move-tmp-") {
                    found.append("\(parent)/\(name)")
                }
            }
        } catch {
            errors.append("\(parent): \(scandirErrorDescription(path: parent, error: error))")
        }
    }

    return (found.sorted(), errors.isEmpty ? nil : errors.joined(separator: "; "))
}

private func buildRecoverRecommendation(
    state: String,
    oldExists: Bool,
    newExists: Bool
) -> String {
    if state == "committed" {
        if newExists && !oldExists { return "OK — move completed as logged." }
        if oldExists && !newExists {
            return "Anomaly — log says committed but src still exists. Investigate manually; consider `engram project undo <id>`."
        }
        return "Anomaly — both or neither paths present. Investigate."
    }
    if state == "fs_pending" {
        if oldExists && !newExists {
            return "FS untouched. Safe to ignore; retry the move when ready. The stale log row auto-fails after 24h."
        }
        if oldExists && newExists {
            return "Both paths exist — partial fs.cp may have occurred. Inspect new path; remove it manually if bogus."
        }
        if !oldExists && newExists {
            return "Move seems to have actually succeeded; DB log did not catch up. Manual fix: UPDATE migration_log SET state='committed' WHERE id=<this>. Then re-run `engram project move` to sync DB cwd/source_locator."
        }
        return "Neither path exists — something catastrophic happened. Restore from backup."
    }
    if state == "fs_done" {
        if !oldExists && newExists {
            return "FS move succeeded; DB commit failed mid-way. To finish: either (a) mv the new path back to the old path and retry `engram project move`, or (b) mark the migration committed directly — connect to ~/.engram/index.sqlite and run `UPDATE migration_log SET state='committed' WHERE id='<this>'`, then run `engram project review <oldPath> <newPath>` to check residual refs. Re-running `engram project move <oldPath> <newPath>` as-is WILL NOT work (src gone, dst exists)."
        }
        if oldExists && newExists {
            return "Both paths exist — FS work may have been partially undone. Inspect both; prefer manual mv back over retry."
        }
        return "Unexpected state. Investigate manually."
    }
    if state == "failed" {
        if oldExists && !newExists {
            return "Compensation succeeded — src is back where it started. Safe to ignore and retry later."
        }
        if !oldExists && newExists {
            return "FS move completed but DB commit failed and compensation did not reverse the FS. Either (a) manually mv new → old then retry `engram project move`, or (b) mark committed directly: `UPDATE migration_log SET state='committed' WHERE id='<this>'` then `engram project review`."
        }
        if oldExists && newExists {
            return "Both paths exist — compensation ran partially. Inspect, then `engram project move` (or manual mv) to reach a consistent state."
        }
        return "Neither path exists — likely data loss. Restore from backup."
    }
    return "Unknown state"
}

private func scandirErrorDescription(path: String, error: Error) -> String {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain &&
        (nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError) {
        return "ENOENT: no such file or directory, scandir '\(path)'"
    }
    return nsError.localizedDescription
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
