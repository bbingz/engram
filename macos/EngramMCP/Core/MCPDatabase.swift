import Foundation
import GRDB
import EngramCoreRead

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
    private final class SharedReader: @unchecked Sendable {
        let queue: DatabaseQueue
        let immediateQueue: DatabaseQueue
        let availabilityLock = NSLock()
        var lastAvailability: SessionVectorSearchAvailability.Snapshot?

        init(path: String) throws {
            // Open fail-fast so a process launched during an exclusive lock does
            // not spend 30 seconds constructing its process-long reader. Once
            // open, ordinary MCP reads regain the standard reader timeout; only
            // vector probes temporarily switch back to zero below.
            var configuration = SQLiteConnectionPolicy.readerConfiguration(
                busyTimeoutMilliseconds: 0
            )
            configuration.prepareDatabase { db in
                db.add(function: DatabaseFunction(
                    "engram_redacted_keyword_snippet",
                    argumentCount: 2,
                    pure: true
                ) { values in
                    guard let content = String.fromDatabaseValue(values[0]),
                          let query = String.fromDatabaseValue(values[1])
                    else {
                        return ""
                    }
                    return redactedKeywordSnippet(content: content, query: query)
                })
            }
            queue = try DatabaseQueue(path: path, configuration: configuration)
            try queue.read { db in
                try db.execute(
                    sql: "PRAGMA busy_timeout = \(SQLiteConnectionPolicy.busyTimeoutMilliseconds)"
                )
            }
            immediateQueue = try DatabaseQueue(
                path: path,
                configuration: SQLiteConnectionPolicy.immediateReaderConfiguration()
            )
        }
    }

    private static let sharedReadersLock = NSLock()
    private static var sharedReaders: [String: SharedReader] = [:]

    private let reader: SharedReader
    private var queue: DatabaseQueue { reader.queue }
    private let databasePath: String

    init(path: String) throws {
        databasePath = path
        Self.sharedReadersLock.lock()
        defer { Self.sharedReadersLock.unlock() }
        if let existing = Self.sharedReaders[path] {
            reader = existing
        } else {
            let opened = try SharedReader(path: path)
            Self.sharedReaders[path] = opened
            reader = opened
        }
    }

    /// Schema advertising is nonblocking and retains the last real visibility-
    /// filtered snapshot during transient BUSY/LOCKED windows. It never turns an
    /// unknown lock state into a fabricated usable corpus.
    func vectorAvailabilityForAdvertising() -> SessionVectorSearchAvailability.Snapshot {
        do {
            let snapshot = try reader.immediateQueue.read { db in
                try SessionVectorSearchAvailability.probe(
                    db: db,
                    requireUnorphanedSessions: true
                )
            }
            reader.availabilityLock.lock()
            reader.lastAvailability = snapshot
            reader.availabilityLock.unlock()
            return snapshot
        } catch let error as DatabaseError
            where error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_LOCKED {
            reader.availabilityLock.lock()
            defer { reader.availabilityLock.unlock() }
            return reader.lastAvailability ?? .unavailable
        } catch {
            return .unavailable
        }
    }

    /// A tools/call gate must reflect the database state for this request.
    /// Unlike advertising, a transient lock cannot reuse stale usable state.
    func vectorAvailabilityForQuery() throws -> SessionVectorSearchAvailability.Snapshot {
        try reader.immediateQueue.read { db in
            try SessionVectorSearchAvailability.probe(
                db: db,
                requireUnorphanedSessions: true
            )
        }
    }

    private func readImmediate<T>(_ body: (Database) throws -> T) throws -> T {
        try reader.immediateQueue.read(body)
    }

    #if DEBUG
    private static func waitForHybridKeywordFusionTestBarrierIfConfigured() {
        guard let directory = ProcessInfo.processInfo.environment[
            "ENGRAM_MCP_TEST_HYBRID_KEYWORD_BARRIER_DIR"
        ], !directory.isEmpty else {
            return
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let ready = root.appendingPathComponent("ready")
        let release = root.appendingPathComponent("release")
        try? Data().write(to: ready, options: .atomic)
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: release.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
    #endif

    func stats(groupBy: String, since: String?, until: String?) throws -> OrderedJSONValue {
        let activityTime = SearchFilterPredicates.activityTimeSQL(alias: "s")
        let groupExpr: String
        switch groupBy {
        case "project":
            groupExpr = "COALESCE(s.project, '(unknown)')"
        case "day":
            groupExpr = "COALESCE(date(\(activityTime), 'localtime'), '(unknown)')"
        case "week":
            groupExpr = "COALESCE(date(\(activityTime), 'localtime', 'weekday 0', '-6 days'), '(unknown)')"
        default:
            groupExpr = "s.source"
        }

        // R3/M5: sessionCount / totals exclude skip-tier (match app KPI aggregates).
        // orphan_status remains MCP-specific (app surfaces do not filter it).
        var conditions = [
            SessionVisibilityFilter.listVisibleSQL(alias: "s"),
            "s.orphan_status IS NULL",
        ]
        var arguments: [String: DatabaseValueConvertible?] = [:]
        if let since {
            conditions.append("\(activityTime) >= :since")
            arguments["since"] = since
        }
        if let until {
            conditions.append("\(activityTime) <= :until")
            arguments["until"] = until
        }

        let sql = """
        SELECT \(groupExpr) AS key,
               COUNT(*) AS sessionCount,
               SUM(message_count) AS messageCount,
               SUM(user_message_count) AS userMessageCount,
               SUM(assistant_message_count) AS assistantMessageCount,
               SUM(tool_message_count) AS toolMessageCount
        FROM sessions s
        WHERE \(conditions.joined(separator: " AND "))
        GROUP BY \(groupExpr)
        ORDER BY sessionCount DESC
        """

        let (rows, indexJobCounts) = try queue.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            let jobRows = try Row.fetchAll(db, sql: """
                SELECT status, COUNT(*) as count
                FROM session_index_jobs
                GROUP BY status
                """)
            let jobCounts = Dictionary(uniqueKeysWithValues: jobRows.map { row in
                (row["status"] as String, intValue(row["count"]))
            })
            return (rows, jobCounts)
        }
        let groups = rows.map { row in
            OrderedJSONValue.object([
                ("key", .string(stringValue(row["key"]) ?? "(unknown)")),
                ("sessionCount", .int(intValue(row["sessionCount"]))),
                ("messageCount", .int(intValue(row["messageCount"]))),
                ("userMessageCount", .int(intValue(row["userMessageCount"]))),
                ("assistantMessageCount", .int(intValue(row["assistantMessageCount"]))),
                ("toolMessageCount", .int(intValue(row["toolMessageCount"]))),
            ])
        }
        let totalSessions = rows.reduce(0) { partial, row in
            partial + intValue(row["sessionCount"])
        }
        let indexJobs = OrderedJSONValue.object(IndexJobStatus.allCases.map { status in
            (status.rawValue, .int(indexJobCounts[status.rawValue] ?? 0))
        })

        return .object([
            ("groupBy", .string(groupBy)),
            ("groups", .array(groups)),
            ("indexJobs", indexJobs),
            ("totalSessions", .int(totalSessions)),
        ])
    }

    func listSessions(
        source: String?,
        project: String?,
        since: String?,
        until: String?,
        limit: Int,
        offset: Int,
        includeAll: Bool = false
    ) throws -> OrderedJSONValue {
        // docs/invariants.md #3: include_all may relax human-driven scoring,
        // but never tier visibility or top-level grouping.
        let hasHumanDrivenColumns = (try? sessionsHaveHumanDrivenColumns()) == true
        let hasOrphanStatusColumn = (try? sessionsHaveOrphanStatusColumn()) == true
        var conditions = [
            SessionVisibilityFilter.listVisibleSQL(alias: "s"),
            SessionVisibilityFilter.topLevelOrPromotedSuggestedSQL(
                alias: "s",
                hasHumanDrivenColumns: hasHumanDrivenColumns,
                hasOrphanStatusColumn: hasOrphanStatusColumn,
                applyHumanDrivenOnHost: !includeAll,
                applyHumanDrivenOnChild: !includeAll
            ),
        ]
        if hasOrphanStatusColumn {
            conditions.append("s.orphan_status IS NULL")
        }
        var values: [DatabaseValueConvertible?] = []
        if let source {
            conditions.append("source = ?")
            values.append(source)
        }
        if let project {
            let projects = try resolveProjectAliases([project])
            if !projects.isEmpty {
                let placeholders = Array(repeating: "?", count: projects.count).joined(separator: ", ")
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
        let countValues = values
        values.append(limit)
        values.append(offset)

        let sql = """
        SELECT base.*, ls.local_readable_path
        FROM (
          SELECT *
          FROM sessions s
          WHERE \(conditions.joined(separator: " AND "))
          ORDER BY start_time DESC
          LIMIT ? OFFSET ?
        ) base
        LEFT JOIN session_local_state ls ON ls.session_id = base.id
        ORDER BY base.start_time DESC
        """

        let totalSQL = """
        SELECT COUNT(*)
        FROM sessions s
        WHERE \(conditions.joined(separator: " AND "))
        """

        let (rows, total) = try queue.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(values))
            let total = try Int.fetchOne(db, sql: totalSQL, arguments: StatementArguments(countValues)) ?? rows.count
            return (rows, total)
        }

        return .object([
            ("sessions", .array(rows.map(listSessionObject(from:)))),
            ("total", .int(total)),
        ])
    }

    func getCosts(groupBy: String, since: String?, until: String?) throws -> OrderedJSONValue {
        let activityTime = SearchFilterPredicates.activityTimeSQL(alias: "s")
        let groupExpr: String
        switch groupBy {
        case "source":
            groupExpr = "s.source"
        case "project":
            groupExpr = "s.project"
        case "day":
            // M24: local day — parity with service costs / heatmaps.
            groupExpr = "date(\(activityTime), 'localtime')"
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
        WHERE \(SessionVisibilityFilter.listVisibleSQL(alias: "s"))
        """
        var arguments: [String: DatabaseValueConvertible?] = [:]
        if let since {
            sql += " AND \(activityTime) >= :since"
            arguments["since"] = since
        }
        if let until {
            sql += " AND \(activityTime) < :until"
            arguments["until"] = until
        }
        sql += " GROUP BY \(groupExpr) ORDER BY costUsd DESC"

        // Unpriced cause split (row 4): same WHERE predicate, whole-window aggregates.
        // Must run as a sibling fetch inside the same `queue.read` closure — nested
        // `queue.read` deadlocks (GRDB non-reentrant).
        var unpricedSQL = """
        SELECT
          SUM(CASE WHEN COALESCE(c.cost_usd,0)=0
                   AND (c.input_tokens+c.output_tokens+c.cache_read_tokens+c.cache_creation_tokens) > 0
                   AND (c.model IS NULL OR c.model = '')
              THEN 1 ELSE 0 END) AS unpricedUnattributedSessions,
          SUM(CASE WHEN COALESCE(c.cost_usd,0)=0
                   AND (c.input_tokens+c.output_tokens+c.cache_read_tokens+c.cache_creation_tokens) > 0
                   AND c.model IS NOT NULL AND c.model <> ''
              THEN 1 ELSE 0 END) AS unpricedNoPriceSessions,
          SUM(CASE WHEN COALESCE(c.cost_usd,0)=0
                   AND (c.input_tokens+c.output_tokens+c.cache_read_tokens+c.cache_creation_tokens) > 0
                   AND (c.model IS NULL OR c.model = '')
              THEN (c.input_tokens+c.output_tokens+c.cache_read_tokens+c.cache_creation_tokens)
              ELSE 0 END) AS unpricedUnattributedTokens,
          SUM(CASE WHEN COALESCE(c.cost_usd,0)=0
                   AND (c.input_tokens+c.output_tokens+c.cache_read_tokens+c.cache_creation_tokens) > 0
                   AND c.model IS NOT NULL AND c.model <> ''
              THEN (c.input_tokens+c.output_tokens+c.cache_read_tokens+c.cache_creation_tokens)
              ELSE 0 END) AS unpricedNoPriceTokens
        FROM session_costs c
        JOIN sessions s ON c.session_id = s.id
        WHERE \(SessionVisibilityFilter.listVisibleSQL(alias: "s"))
        """
        if since != nil {
            unpricedSQL += " AND \(activityTime) >= :since"
        }
        if until != nil {
            unpricedSQL += " AND \(activityTime) < :until"
        }

        let (rows, unpriced): ([Row], Row?) = try queue.read { db in
            let grouped = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            let unpricedRow = try Row.fetchOne(
                db,
                sql: unpricedSQL,
                arguments: StatementArguments(arguments)
            )
            return (grouped, unpricedRow)
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
            ("unpricedUnattributedSessions", .int(intValue(unpriced?["unpricedUnattributedSessions"]))),
            ("unpricedNoPriceSessions", .int(intValue(unpriced?["unpricedNoPriceSessions"]))),
            ("unpricedUnattributedTokens", .int(intValue(unpriced?["unpricedUnattributedTokens"]))),
            ("unpricedNoPriceTokens", .int(intValue(unpriced?["unpricedNoPriceTokens"]))),
            ("breakdown", .array(rows.map(costSummaryObject(from:)))),
        ])
    }

    func getToolAnalytics(project: String?, since: String?, groupBy: String) throws -> OrderedJSONValue {
        let activityTime = SearchFilterPredicates.activityTimeSQL(alias: "s")
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

        let visibilityConditions = defaultSessionVisibilityConditions(alias: "s")
        var sql = """
        SELECT \(selectColumns)
        FROM session_tools t
        JOIN sessions s ON t.session_id = s.id
        WHERE \(visibilityConditions.joined(separator: " AND "))
        """
        var arguments: [String: DatabaseValueConvertible?] = [:]
        if let project {
            sql += " AND s.project LIKE :project ESCAPE '\\'"
            arguments["project"] = "%\(escapeLike(project))%"
        }
        if let since {
            sql += " AND \(activityTime) >= :since"
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
        var conditions = defaultSessionVisibilityConditions(alias: "s")
        var arguments: [String: DatabaseValueConvertible?] = [:]
        if let project {
            let projects = try resolveProjectAliases([project])
            let parameters = projects.indices.map { ":project\($0)" }
            conditions.append("s.project IN (\(parameters.joined(separator: ", ")))")
            for (index, value) in projects.enumerated() {
                arguments["project\(index)"] = value
            }
        }
        if let since {
            conditions.append("COALESCE(NULLIF(s.end_time, ''), s.start_time) >= :since")
            arguments["since"] = since
        }
        arguments["limit"] = limit

        let sql = """
        SELECT sf.file_path, sf.action,
               SUM(sf.count) AS total_count,
               COUNT(DISTINCT sf.session_id) AS session_count
        FROM session_files sf
        JOIN sessions s ON s.id = sf.session_id
        WHERE \(conditions.joined(separator: " AND "))
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
                    ("file_path", .string(stringValue(row["file_path"]) ?? "")),
                    ("action", .string(stringValue(row["action"]) ?? "")),
                    ("total_count", .int(intValue(row["total_count"]))),
                    ("session_count", .int(intValue(row["session_count"]))),
                ])
            })),
            ("totalFiles", .int(rows.count)),
        ])
    }

    func projectTimeline(project: String, since: String?, until: String?) throws -> OrderedJSONValue {
        var conditions = defaultSessionVisibilityConditions(alias: "s") + ["s.orphan_status IS NULL"]
        var values: [DatabaseValueConvertible?] = []
        let activityTime = SearchFilterPredicates.activityTimeSQL()
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
            conditions.append("\(activityTime) >= ?")
            values.append(since)
        }
        if let until {
            conditions.append("\(activityTime) <= ?")
            values.append(until)
        }
        let total = try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sessions s WHERE \(conditions.joined(separator: " AND "))",
                arguments: StatementArguments(values)
            ) ?? 0
        }
        values.append(200)

        let sql = """
        SELECT id, source, start_time, \(activityTime) AS activity_time, summary, message_count
        FROM sessions s
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY activity_time DESC
        LIMIT ?
        """
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(values))
        }
        let timeline = rows
            .map { row in
                OrderedJSONValue.object([
                    ("time", .string(toLocalDateTime(stringValue(row["activity_time"])))),
                    ("source", .string(stringValue(row["source"]) ?? "unknown")),
                    ("summary", .string(redactedSessionMetadata(row["summary"]) ?? "（无摘要）")),
                    ("sessionId", .string(stringValue(row["id"]) ?? "")),
                    ("messageCount", .int(intValue(row["message_count"]))),
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
            ("total", .int(total)),
            ("hasMore", .bool(total > timeline.count)),
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
        return .object([
            ("migrations", .array(rows.map(migrationObject(from:)))),
        ])
    }

    func getMemory(query: String, type: String? = nil) async throws -> OrderedJSONValue {
        let insightType = try Self.normalizeMemoryTypeFilter(type)
        let lifecycleAware = (try? insightsHasLifecycleColumns()) == true
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasKeywordQuery = !trimmedQuery.isEmpty
        if hasKeywordQuery, trimmedQuery.count < 2 {
            return Self.emptyMemoryResult(
                type: insightType,
                warning: "Queries must contain at least two characters."
            )
        }

        // Hybrid keyword + semantic when an embedding provider is configured and
        // embeddings exist. Any failure degrades to keyword with a warning that
        // names the *actual* reason (M07) — never a blanket "No embedding provider"
        // when the provider was present, and never embed on model mismatch.
        var degradeReason: SessionVectorSearchAvailability.SemanticDegradeReason?
        var degradeDetail: String?
        if let config = EmbeddingSettings.load() {
            let insightMeta: (model: String, dimension: Int)?
            do {
                insightMeta = try probeInsightEmbeddingMeta()
            } catch let error as DatabaseError
                where error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_LOCKED {
                insightMeta = nil
                degradeReason = .embedFailed
                degradeDetail = "database is busy"
            } catch {
                insightMeta = nil
                degradeReason = .embedFailed
                degradeDetail = error.localizedDescription
            }
            if let insightMeta {
                let snapshot = SessionVectorSearchAvailability.Snapshot(
                    isUsable: true,
                    model: insightMeta.model,
                    dimension: insightMeta.dimension
                )
                switch SessionVectorSearchAvailability.queryCompatibility(
                    configuredModel: config.model,
                    configuredDimension: config.dimension,
                    dimensionsWereSent: EmbeddingRequestPolicy.dimensionsWereSentForCompatibility(
                        config,
                        storedDimension: insightMeta.dimension
                    ),
                    snapshot: snapshot
                ) {
                case .compatible:
                    do {
                        let hybrid = try await semanticMemory(
                            query: query,
                            config: config,
                            lifecycleAware: lifecycleAware,
                            type: insightType,
                            storedModel: insightMeta.model,
                            storedDim: insightMeta.dimension
                        )
                        if !hybrid.isEmpty {
                            return memoryResult(
                                memories: hybrid.map { memoryObject(from: $0.row, distance: Double($0.distance)) },
                                type: insightType,
                                extra: [("retrieval", .string("hybrid"))]
                            )
                        }
                        // Empty hybrid is not a provider failure — fall through without
                        // mislabeling as providerUnavailable.
                    } catch EmbeddingError.circuitOpen {
                        degradeReason = .breakerOpen
                    } catch EmbeddingError.notConfigured {
                        degradeReason = .providerUnavailable
                    } catch let EmbeddingError.dimensionMismatch(expected, actual) {
                        degradeReason = .modelMismatch
                        degradeDetail = "query embedding dim \(actual) vs stored \(expected)"
                    } catch {
                        degradeReason = .embedFailed
                        degradeDetail = error.localizedDescription
                    }
                case .corpusUnavailable:
                    degradeReason = .corpusMissing
                case let .modelMismatch(cfgModel, cfgDim, storedModel, storedDim):
                    // Fail closed: no provider call and no ranking on mismatch.
                    degradeReason = .modelMismatch
                    degradeDetail = "configured \(cfgModel)@\(cfgDim) vs stored \(storedModel)@\(storedDim)"
                }
            } else if degradeReason == nil {
                degradeReason = .corpusMissing
            }
        } else {
            degradeReason = .providerUnavailable
        }

        // Only claim "No embedding provider" when that is the actual reason.
        let warning = degradeReason?.memoryWarning(detail: degradeDetail)
            ?? "Keyword-matched insights ranked by importance and recency."

        // When the writer has applied the memory-lifecycle migration, rank by
        // importance + recency decay + access and exclude superseded rows. On an
        // un-migrated DB (those columns absent) fall back to the legacy keyword/
        // recency behavior so a read-only MCP never assumes the writer's schema.
        if lifecycleAware {
            if let ranked = try? rankedActiveInsights(query: query, fromRecent: false, type: insightType),
               !ranked.isEmpty {
                return memoryResult(
                    memories: ranked.map { memoryObject(from: $0, distance: 0) },
                    type: insightType,
                    extra: [("warning", .string(warning))]
                )
            }
            if !hasKeywordQuery,
               let ranked = try? rankedActiveInsights(query: query, fromRecent: true, type: insightType),
               !ranked.isEmpty {
                return memoryResult(
                    memories: ranked.map { memoryObject(from: $0, distance: 0) },
                    type: insightType,
                    extra: [("warning", .string(warning))]
                )
            }
            // R1.P1.empty_result_suppresses_degrade: empty hits still surface the
            // degrade/keyword warning so clients can distinguish "no matches"
            // from "semantic path failed closed".
            return Self.emptyMemoryResult(type: insightType, warning: warning)
        }

        if let matches = try? searchInsightsFTS(query: query, limit: 10), !matches.isEmpty {
            let filtered = filterInsights(matches, byType: insightType)
            if !filtered.isEmpty {
                return memoryResult(
                    memories: filtered.map { memoryObject(from: $0, distance: 0) },
                    type: insightType,
                    extra: [("warning", .string(warning))]
                )
            }
        }

        if hasKeywordQuery {
            return Self.emptyMemoryResult(type: insightType, warning: warning)
        }

        let recent = try listInsightsByWing(wing: nil, limit: 10)
        let filteredRecent = filterInsights(recent, byType: insightType)
        if !filteredRecent.isEmpty {
            return memoryResult(
                memories: filteredRecent.map { memoryObject(from: $0, distance: 0) },
                type: insightType,
                extra: [("warning", .string(warning))]
            )
        }

        return Self.emptyMemoryResult(type: insightType, warning: warning)
    }

    /// Build a get_memory structured payload with returned memory `type` fields
    /// and optional requested type filter (L07).
    private func memoryResult(
        memories: [OrderedJSONValue],
        type: String?,
        extra: [(String, OrderedJSONValue)] = []
    ) -> OrderedJSONValue {
        var entries: [(String, OrderedJSONValue)] = [
            ("memories", .array(memories)),
        ]
        if let type {
            entries.append(("type", .string(type)))
        }
        entries.append(contentsOf: extra)
        return .object(entries)
    }

    /// Allowed `insight_type` values (same set as save_insight / half-life switch).
    private static let allowedMemoryTypes: Set<String> = ["episodic", "semantic", "procedural"]

    /// Normalize optional type filter; nil/blank means no filter. Unknown values error.
    private static func normalizeMemoryTypeFilter(_ type: String?) throws -> String? {
        guard let type else { return nil }
        let normalized = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        guard allowedMemoryTypes.contains(normalized) else {
            throw MCPToolError.invalidArguments(
                "type must be one of: episodic, semantic, procedural"
            )
        }
        return normalized
    }

    /// Rows whose `insight_type` matches `type`. Missing column / NULL defaults to semantic.
    private func filterInsights(_ rows: [Row], byType type: String?) -> [Row] {
        guard let type else { return rows }
        return rows.filter { (stringValue($0["insight_type"]) ?? "semantic") == type }
    }

    private static func emptyMemoryResult(type: String? = nil, warning: String? = nil) -> OrderedJSONValue {
        var entries: [(String, OrderedJSONValue)] = [
            ("memories", .array([])),
            ("message", .string("No memories found. Use save_insight to add knowledge that persists across sessions.")),
        ]
        if let type {
            entries.insert(("type", .string(type)), at: 1)
        }
        if let warning, !warning.isEmpty {
            entries.append(("warning", .string(warning)))
        }
        return .object(entries)
    }

    /// Default browse visibility shared by `list_sessions` and secondary MCP
    /// reads. A read-only MCP over an un-migrated DB skips only the human-driven
    /// predicate, matching the existing `list_sessions` compatibility behavior.
    private func defaultSessionVisibilityConditions(alias: String) -> [String] {
        let hasHumanDrivenColumns = (try? sessionsHaveHumanDrivenColumns()) == true
        let hasOrphanStatusColumn = (try? sessionsHaveOrphanStatusColumn()) == true
        var conditions = [
            SessionVisibilityFilter.listVisibleSQL(alias: alias),
            SessionVisibilityFilter.topLevelOrPromotedSuggestedSQL(
                alias: alias,
                hasHumanDrivenColumns: hasHumanDrivenColumns,
                hasOrphanStatusColumn: hasOrphanStatusColumn
            ),
        ]

        if hasOrphanStatusColumn {
            conditions.append("\(alias).orphan_status IS NULL")
        }
        return conditions
    }

    private func sessionsHaveOrphanStatusColumn() throws -> Bool {
        try queue.read { db in
            try db.columns(in: "sessions").contains { $0.name == "orphan_status" }
        }
    }

    /// True when the `sessions` table carries the human-driven signal columns.
    private func sessionsHaveHumanDrivenColumns() throws -> Bool {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(sessions)")
            let names = Set(rows.compactMap { $0["name"] as String? })
            return names.contains("instruction_count") && names.contains("human_turn_count")
        }
    }

    /// True when the `insights` table carries the memory-lifecycle columns
    /// (`superseded_by` / `insight_type` / `access_count`).
    private func insightsHasLifecycleColumns() throws -> Bool {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(insights)")
            let names = Set(rows.compactMap { $0["name"] as String? })
            return names.contains("superseded_by")
                && names.contains("insight_type")
                && names.contains("access_count")
        }
    }

    /// Active (non-superseded) insights for `query`, lifecycle-ranked, top 10.
    private func rankedActiveInsights(query: String, fromRecent: Bool, type: String?) throws -> [Row] {
        let candidates = fromRecent
            ? try listInsightsByWing(wing: nil, limit: 40)
            : try searchInsightsFTS(query: query, limit: 40)
        let active = candidates.filter { stringValue($0["superseded_by"]) == nil }
        let typed = filterInsights(active, byType: type)
        guard !typed.isEmpty else { return [] }
        return Array(rankInsightsByLifecycle(typed, relevanceOrdered: !fromRecent).prefix(10))
    }

    /// `score = relevance · importanceBoost · recencyDecay · accessBoost`.
    /// `relevanceOrdered` rows arrive best-first (FTS rank); recency-fallback
    /// rows get uniform relevance so importance/decay decide.
    private func rankInsightsByLifecycle(_ rows: [Row], relevanceOrdered: Bool) -> [Row] {
        let now = contextNow()
        let scored = rows.enumerated().map { index, row -> (offset: Int, row: Row, score: Double) in
            let relevance = relevanceOrdered ? 1.0 / Double(index + 1) : 1.0
            let importance = Double(max(0, min(10, intValue(row["importance"]))))
            let importanceBoost = 0.6 + 0.4 * (importance / 5.0)
            let ageDays = insightAgeInDays(stringValue(row["created_at"]), now: now)
            let halfLife = insightHalfLifeDays(forType: stringValue(row["insight_type"]))
            let recencyDecay = pow(2.0, -ageDays / halfLife)
            let access = Double(max(0, intValue(row["access_count"])))
            let accessBoost = 1.0 + 0.1 * log(1.0 + access)
            return (index, row, relevance * importanceBoost * recencyDecay * accessBoost)
        }
        return scored
            .sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : lhs.offset < rhs.offset
            }
            .map(\.row)
    }

    private func insightHalfLifeDays(forType type: String?) -> Double {
        switch type {
        case "episodic": return 14
        case "procedural": return 90
        default: return 30
        }
    }

    private func insightAgeInDays(_ createdAt: String?, now: Date) -> Double {
        guard let createdAt, let date = parseInsightTimestamp(createdAt) else { return 0 }
        return max(0, now.timeIntervalSince(date) / 86_400)
    }

    private func parseInsightTimestamp(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        let isoPlain = ISO8601DateFormatter()
        if let date = isoPlain.date(from: raw) { return date }
        let sqlite = DateFormatter()
        sqlite.locale = Locale(identifier: "en_US_POSIX")
        sqlite.timeZone = TimeZone(secondsFromGMT: 0)
        sqlite.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return sqlite.date(from: raw)
    }

    // MARK: - Semantic memory (hybrid keyword + vector)

    private func hasInsightEmbeddings() throws -> Bool {
        try probeInsightEmbeddingMeta() != nil
    }

    /// Probe authoritative stored (model, dimension) for insight embeddings.
    ///
    /// `embedding_meta` id=1 is the sole source of truth for model+dimension
    /// (backfill only fills missing insight rows while meta can advance). At
    /// least one `insight_embeddings` row must match that exact model+dim with
    /// a non-null BLOB. Mixed leftover old-model rows are ignored. Returns nil
    /// (corpusMissing) when meta is missing/unusable or no matching insight
    /// row exists — never an unordered LIMIT 1 sample of insight_embeddings.
    private func probeInsightEmbeddingMeta() throws -> (model: String, dimension: Int)? {
        try readImmediate { db in
            let hasMeta = try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='embedding_meta'"
            ) != nil
            let hasInsights = try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='insight_embeddings'"
            ) != nil
            guard hasMeta, hasInsights else { return nil }

            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT model, dimension
                FROM embedding_meta
                WHERE id = 1
                LIMIT 1
                """
            ) else {
                return nil
            }
            let model = (row["model"] as String?)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let dimension = row["dimension"] as Int?
            guard let model, !model.isEmpty, let dimension, dimension > 0 else { return nil }

            let hasCompatible = try Int.fetchOne(
                db,
                sql: """
                SELECT 1
                FROM insight_embeddings
                WHERE embedding IS NOT NULL
                  AND model = ?
                  AND dim = ?
                LIMIT 1
                """,
                arguments: [model, dimension]
            ) != nil
            guard hasCompatible else { return nil }
            return (model, dimension)
        }
    }

    private func insightEmbeddingCandidates(
        model: String,
        dim: Int,
        lifecycleAware: Bool
    ) throws -> [VectorSearch.Candidate] {
        let lifecyclePredicate = lifecycleAware ? "AND i.superseded_by IS NULL" : ""
        let rows = try readImmediate { db in
            return try Row.fetchAll(
                db,
                sql: """
                SELECT e.insight_id, e.embedding
                FROM insight_embeddings e
                JOIN insights i ON i.id = e.insight_id
                WHERE e.embedding IS NOT NULL
                  AND e.model = ?
                  AND e.dim = ?
                  \(lifecyclePredicate)
                """,
                arguments: [model, dim]
            )
        }
        var candidates: [VectorSearch.Candidate] = []
        for row in rows {
            guard let id = stringValue(row["insight_id"]) else { continue }
            let blob: Data? = row["embedding"]
            guard let data = blob else { continue }
            guard let vector = VectorMath.decode(data, expectedCount: dim) else { continue }
            candidates.append(VectorSearch.Candidate(id: id, vector: vector))
        }
        return candidates
    }

    private func insightRowById(_ id: String) throws -> Row? {
        try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM insights WHERE id = ? LIMIT 1", arguments: [id])
        }
    }

    /// Embed the query, KNN over stored insight embeddings, fuse with the FTS
    /// keyword ranking via RRF, then drop superseded rows (and optional type).
    /// Top 10. Uses `EmbeddingGuardrails.sharedBreaker` (M08) — no private bypass.
    /// Caller must already enforce model+dim equality (M07).
    private func semanticMemory(
        query: String,
        config: EmbeddingConfig,
        lifecycleAware: Bool,
        type: String?,
        storedModel: String,
        storedDim: Int
    ) async throws -> [(row: Row, distance: Float)] {
        let client = EmbeddingGuardrails.guardedProvider(
            for: config,
            breaker: EmbeddingGuardrails.sharedBreaker
        )
        let vectors = try await client.embed([query])
        guard let queryVector = vectors.first, !queryVector.isEmpty else { return [] }
        guard queryVector.count == storedDim else {
            throw EmbeddingError.dimensionMismatch(
                expected: storedDim,
                actual: queryVector.count
            )
        }

        let candidates = try insightEmbeddingCandidates(
            model: storedModel,
            dim: storedDim,
            lifecycleAware: lifecycleAware
        )
        guard !candidates.isEmpty else { return [] }

        let knn = VectorSearch.knn(query: queryVector, candidates: candidates, topK: 40)
        let semanticIds = knn.map(\.id)
        let keywordIds = ((try? searchInsightsFTS(query: query, limit: 40)) ?? [])
            .compactMap { stringValue($0["id"]) }
        let fused = RankFusion.rrf([semanticIds, keywordIds])
        let scoreById = Dictionary(knn.map { ($0.id, $0.score) }, uniquingKeysWith: { first, _ in first })

        var results: [(row: Row, distance: Float)] = []
        for entry in fused {
            guard let row = try insightRowById(entry.id) else { continue }
            if lifecycleAware, stringValue(row["superseded_by"]) != nil { continue }
            if let type, (stringValue(row["insight_type"]) ?? "semantic") != type { continue }
            results.append((row, 1 - (scoreById[entry.id] ?? 0)))
            if results.count >= 10 { break }
        }
        return results
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

        return .object([
            ("diagnostics", .array(diagnoses)),
        ])
    }

    enum SearchError: Error, LocalizedError {
        case modeUnavailable(String)
        case semanticFailed(String)
        /// H07: configured query model/dim does not exactly match embedding_meta.
        case embeddingModelMismatch(
            configuredModel: String,
            storedModel: String,
            configuredDimension: Int,
            storedDimension: Int
        )
        case breakerOpen

        var errorDescription: String? {
            switch self {
            case .modeUnavailable(let mode):
                return "Search mode '\(mode)' is unavailable; session embeddings are not usable. Configure an embedding provider and wait for semantic_chunks backfill, or use mode 'keyword'."
            case .semanticFailed(let detail):
                return "Semantic search failed: \(detail)"
            case let .embeddingModelMismatch(cfgModel, storedModel, cfgDim, storedDim):
                return "Embedding model mismatch: configured \(cfgModel) (dim \(cfgDim)) does not match stored \(storedModel) (dim \(storedDim)). Rebuild embeddings or align the configured model."
            case .breakerOpen:
                return "Semantic search unavailable: embedding circuit breaker is open. Retry after cooldown or use mode 'keyword'."
            }
        }

        var structuredCode: String {
            switch self {
            case .modeUnavailable:
                return "searchModeUnavailable"
            case .semanticFailed:
                return "searchFailed"
            case .embeddingModelMismatch:
                return "embeddingModelMismatch"
            case .breakerOpen:
                return "embeddingCircuitOpen"
            }
        }
    }

    func searchSessions(
        query: String,
        source: String?,
        project: String?,
        since: String?,
        limit: Int,
        mode: String
    ) async throws -> OrderedJSONValue {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cappedLimit = min(max(limit, 1), 50)
        let normalizedMode = mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let effectiveMode = normalizedMode.isEmpty ? "keyword" : normalizedMode
        let semanticRequested = ["semantic", "hybrid", "both"].contains(effectiveMode)

        if isUUID(normalizedQuery) {
            // docs/invariants.md #3: UUID search is still a search surface;
            // unlike get_session, it must not expose hidden or non-searchable tiers.
            if let row = try fetchSearchableSessionRow(id: normalizedQuery) {
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

        // H2: CJK and short Latin queries use LIKE (same as app/service), so
        // do not reject them at the 3-char FTS gate. L-a: still honor the
        // app/service 2-character floor so 1-char LIKE cannot over-recall.
        if normalizedQuery.count < 2 {
            let searchModes: [OrderedJSONValue]
            switch effectiveMode {
            case "semantic":
                searchModes = [.string("semantic")]
            case "hybrid", "both":
                searchModes = [.string("keyword"), .string("semantic")]
            default:
                searchModes = normalizedQuery.isEmpty ? [] : [.string("keyword")]
            }
            return .object([
                ("results", .array([])),
                ("query", .string(query)),
                ("searchModes", .array(searchModes)),
            ])
        }

        // Availability gate (SessionVectorSearchAvailability): never silent
        // keyword fallback for semantic/hybrid when vectors are not usable.
        let availability = semanticRequested
            ? try vectorAvailabilityForQuery()
            : .unavailable
        if semanticRequested, !availability.isUsable {
            throw SearchError.modeUnavailable(effectiveMode)
        }

        if semanticRequested {
            return try await semanticOrHybridSearch(
                query: normalizedQuery,
                originalQuery: query,
                source: source,
                project: project,
                since: since,
                limit: cappedLimit,
                mode: effectiveMode,
                availability: availability
            )
        }

        return try keywordSearchResponse(
            query: normalizedQuery,
            originalQuery: query,
            source: source,
            project: project,
            since: since,
            limit: cappedLimit
        )
    }

    private func keywordSearchResponse(
        query: String,
        originalQuery: String,
        source: String?,
        project: String?,
        since: String?,
        limit: Int
    ) throws -> OrderedJSONValue {
        let ranked = try rankedKeywordMatches(
            query: query,
            source: source,
            project: project,
            since: since,
            limit: limit
        )

        let resultRows = ranked.map { match -> OrderedJSONValue in
            let snippet = match.snippet.isEmpty
                ? (stringValue(match.row["summary"]) ?? "")
                : match.snippet
            return .object([
                ("session", fullSessionObject(from: match.row)),
                ("snippet", .string(keywordSnippet(snippet, query: query))),
                ("matchType", .string("keyword")),
                ("score", .double(match.score)),
            ])
        }

        var entries: [(String, OrderedJSONValue)] = [
            ("results", .array(resultRows)),
            ("query", .string(originalQuery)),
            ("searchModes", .array([.string("keyword")])),
        ]

        if query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 {
            let insightRows = (try? searchInsightsFTS(query: query, limit: 5)) ?? []
            let insightResults = insightRows.compactMap { row -> OrderedJSONValue? in
                guard let content = stringValue(row["content"]), !content.isEmpty else { return nil }
                return .string(TranscriptRedactionPolicy.redact(content))
            }
            if !insightResults.isEmpty {
                entries.append(("insightResults", .array(insightResults)))
            }
        }

        return .object(entries)
    }

    private func rankedKeywordMatches(
        query: String,
        source: String?,
        project: String?,
        since: String?,
        limit: Int,
        immediate: Bool = false
    ) throws -> [(id: String, row: Row, snippet: String, score: Double)] {
        let matches = try keywordSearch(
            query: query,
            source: source,
            project: project,
            since: since,
            limit: limit * 3,
            immediate: immediate
        )

        var seen = Set<String>()
        var ranked: [(id: String, row: Row, snippet: String, score: Double)] = []
        var rank = 1
        for match in matches {
            let sessionID = stringValue(match.row["id"]) ?? ""
            guard !sessionID.isEmpty, seen.insert(sessionID).inserted else { continue }
            // Score uses SessionSemanticSearchPolicy.rrfK so keyword ranks fuse
            // cleanly with RankFusion.rrf in hybrid mode.
            ranked.append((
                sessionID,
                match.row,
                match.snippet,
                1.0 / Double(SessionSemanticSearchPolicy.rrfK + rank)
            ))
            rank += 1
            if ranked.count >= limit { break }
        }
        return ranked
    }

    /// Session semantic/hybrid path — mirrors EngramServiceReadProvider
    /// (brute-force cosine KNN + optional RRF). Coupling constants:
    /// `SessionSemanticSearchPolicy`. Full eligible corpus, not recency-capped.
    private func semanticOrHybridSearch(
        query: String,
        originalQuery: String,
        source: String?,
        project: String?,
        since: String?,
        limit: Int,
        mode: String,
        availability: SessionVectorSearchAvailability.Snapshot
    ) async throws -> OrderedJSONValue {
        guard !query.isEmpty else {
            throw SearchError.semanticFailed("query is empty")
        }
        guard availability.isUsable,
              let metaModel = availability.model,
              let metaDim = availability.dimension,
              metaDim > 0 else {
            throw SearchError.modeUnavailable(mode)
        }
        guard let config = EmbeddingSettings.load() else {
            throw SearchError.modeUnavailable(mode)
        }

        // H07: exact model+dimension match before any query embedding or cosine.
        switch SessionVectorSearchAvailability.queryCompatibility(
            configuredModel: config.model,
            configuredDimension: config.dimension,
            dimensionsWereSent: EmbeddingRequestPolicy.dimensionsWereSentForCompatibility(
                config,
                storedDimension: metaDim
            ),
            snapshot: availability
        ) {
        case .compatible:
            break
        case .corpusUnavailable:
            throw SearchError.modeUnavailable(mode)
        case let .modelMismatch(cfgModel, cfgDim, storedModel, storedDim):
            throw SearchError.embeddingModelMismatch(
                configuredModel: cfgModel,
                storedModel: storedModel,
                configuredDimension: cfgDim,
                storedDimension: storedDim
            )
        }

        // M08: shared process breaker — no private OpenAI client bypass.
        let client = EmbeddingGuardrails.guardedProvider(
            for: config,
            breaker: EmbeddingGuardrails.sharedBreaker
        )
        let vectors: [[Float]]
        do {
            vectors = try await client.embed([query])
        } catch EmbeddingError.circuitOpen {
            throw SearchError.breakerOpen
        } catch {
            throw SearchError.semanticFailed(error.localizedDescription)
        }
        guard let queryVector = vectors.first, !queryVector.isEmpty else {
            throw SearchError.semanticFailed("empty query embedding")
        }
        if queryVector.count != metaDim {
            throw SearchError.embeddingModelMismatch(
                configuredModel: config.model,
                storedModel: metaModel,
                configuredDimension: queryVector.count,
                storedDimension: metaDim
            )
        }

        // M09: full corpus in cancellable bounded batches + constant-memory top-K.
        let topK = SessionSemanticSearchPolicy.knnTopK(limit: limit)
        let topKResult = try await semanticChunkTopK(
            source: source,
            project: project,
            since: since,
            model: metaModel,
            dim: metaDim,
            queryVector: queryVector,
            requestLimit: limit,
            topK: topK
        )
        var semanticSessionIds: [String] = []
        var snippetBySession: [String: String] = [:]
        var scoreBySession: [String: Double] = [:]
        var fallbackSessionById: [String: OrderedJSONValue] = [:]
        for hit in topKResult.hits {
            guard !semanticSessionIds.contains(hit.sessionId) else { continue }
            semanticSessionIds.append(hit.sessionId)
            snippetBySession[hit.sessionId] = hit.text
            scoreBySession[hit.sessionId] = Double(hit.score)
            fallbackSessionById[hit.sessionId] = topKResult.fallbackByChunkId[hit.id]
            if semanticSessionIds.count >= limit { break }
        }
        let semanticItems = try searchResultItems(
            sessionIds: semanticSessionIds,
            snippetBySession: snippetBySession,
            scoreBySession: scoreBySession,
            matchType: "semantic",
            fallbackSessionById: fallbackSessionById
        )
        let insightResults = ((try? searchInsightsFTS(query: query, limit: 5, immediate: true)) ?? []).compactMap { row -> OrderedJSONValue? in
            guard let content = stringValue(row["content"]), !content.isEmpty else { return nil }
            return .string(TranscriptRedactionPolicy.redact(content))
        }

        if mode == "hybrid" || mode == "both" {
            #if DEBUG
            Self.waitForHybridKeywordFusionTestBarrierIfConfigured()
            #endif
            let keywordRanked: [(id: String, row: Row, snippet: String, score: Double)]
            do {
                keywordRanked = try rankedKeywordMatches(
                    query: query,
                    source: source,
                    project: project,
                    since: since,
                    limit: limit,
                    immediate: true
                )
            } catch let error as DatabaseError
                where error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_LOCKED {
                guard !semanticItems.isEmpty else { throw error }
                var entries: [(String, OrderedJSONValue)] = [
                    ("results", .array(semanticItems)),
                    ("query", .string(originalQuery)),
                    ("searchModes", .array([.string("semantic")])),
                    ("warning", .string("Keyword fusion was skipped because the database is busy.")),
                ]
                if !insightResults.isEmpty {
                    entries.append(("insightResults", .array(insightResults)))
                }
                return .object(entries)
            }
            let keywordIds = keywordRanked.map(\.id)
            let fusedIds = RankFusion.rrf(
                [keywordIds, semanticSessionIds],
                k: SessionSemanticSearchPolicy.rrfK
            )
            .prefix(limit)
            .map(\.id)

            // L30: index by each result's session id. zip(ids, items) mislabels
            // when searchResultItems drops a mid-search deleted session (shorter
            // items list). Service uses the same id-keyed pattern.
            let semanticById = MCPSearchResultIndex.bySessionId(semanticItems)
            let keywordById = Dictionary(uniqueKeysWithValues: keywordRanked.map {
                ($0.id, searchResultObject(
                    row: $0.row,
                    snippet: $0.snippet,
                    matchType: "keyword",
                    score: $0.score,
                    query: query
                ))
            })

            let fusedItems = fusedIds.compactMap { id in
                semanticById[id] ?? keywordById[id]
            }

            var entries: [(String, OrderedJSONValue)] = [
                ("results", .array(fusedItems)),
                ("query", .string(originalQuery)),
                ("searchModes", .array([.string("keyword"), .string("semantic")])),
            ]
            if !insightResults.isEmpty {
                entries.append(("insightResults", .array(insightResults)))
            }
            return .object(entries)
        }

        var entries: [(String, OrderedJSONValue)] = [
            ("results", .array(semanticItems)),
            ("query", .string(originalQuery)),
            ("searchModes", .array([.string("semantic")])),
        ]
        if !insightResults.isEmpty {
            entries.append(("insightResults", .array(insightResults)))
        }
        return .object(entries)
    }

    private struct SemanticChunkCandidate {
        let rowID: Int64
        let chunkId: String
        let sessionId: String
        let text: String
        let vector: [Float]
        let session: OrderedJSONValue
    }

    /// Raw SQL page cursor is independent of successful vector decode.
    private struct SemanticChunkPage {
        let candidates: [SemanticChunkCandidate]
        /// Last `sc.rowid` in the raw SQL page; `nil` only when the page is empty.
        let lastRawRowID: Int64?
    }

    private struct SemanticTopKResult {
        let hits: [SessionSemanticSearchPolicy.ScoredChunk]
        let fallbackByChunkId: [String: OrderedJSONValue]
    }

    /// Full-corpus stream: page by raw rowid, accumulate constant-memory top-K.
    /// Cursor advances from raw page last rowid so a full malformed page does not
    /// terminate the scan (M09).
    private func semanticChunkTopK(
        source: String?,
        project: String?,
        since: String?,
        model: String,
        dim: Int,
        queryVector: [Float],
        requestLimit: Int,
        topK: Int
    ) async throws -> SemanticTopKResult {
        var top: [SessionSemanticSearchPolicy.ScoredChunk] = []
        var fallbackByChunkId: [String: OrderedJSONValue] = [:]
        var afterRowID: Int64 = 0
        let batchSize = SessionSemanticSearchPolicy.candidateBatchSize(requestLimit: requestLimit)

        while true {
            try Task.checkCancellation()
            let page = try fetchSemanticChunkPage(
                source: source,
                project: project,
                since: since,
                model: model,
                dim: dim,
                afterRowID: afterRowID,
                batchSize: batchSize
            )
            guard let lastRaw = page.lastRawRowID else { break }
            afterRowID = lastRaw
            for candidate in page.candidates {
                let score = VectorMath.cosine(queryVector, candidate.vector)
                SessionSemanticSearchPolicy.accumulateTopK(
                    &top,
                    incoming: SessionSemanticSearchPolicy.ScoredChunk(
                        id: candidate.chunkId,
                        score: score,
                        sessionId: candidate.sessionId,
                        text: candidate.text
                    ),
                    topK: topK
                )
                fallbackByChunkId[candidate.chunkId] = candidate.session
                let retained = Set(top.map(\.id))
                fallbackByChunkId = fallbackByChunkId.filter { retained.contains($0.key) }
            }
        }
        return SemanticTopKResult(hits: top, fallbackByChunkId: fallbackByChunkId)
    }

    private func fetchSemanticChunkPage(
        source: String?,
        project: String?,
        since: String?,
        model: String,
        dim: Int,
        afterRowID: Int64,
        batchSize: Int
    ) throws -> SemanticChunkPage {
        let expandedProjects = try project.map {
            try resolveProjectAliases([$0], immediate: true)
        } ?? []
        return try readImmediate { db in
            var conditions = [
                "sc.embedding IS NOT NULL",
                "sc.model = ?",
                "sc.dim = ?",
                "sc.rowid > ?",
                "s.hidden_at IS NULL",
                "s.orphan_status IS NULL",
                SessionSemanticSearchPolicy.searchableTierSQL,
            ]
            var values: [DatabaseValueConvertible?] = [model, dim, afterRowID]

            Self.appendSearchFilterPredicates(
                source: source,
                expandedProjects: expandedProjects,
                since: since,
                conditions: &conditions,
                values: &values
            )
            values.append(batchSize)

            let sql = """
            SELECT sc.rowid AS row_id,
                   sc.id AS chunk_id,
                   sc.session_id AS session_id,
                   sc.text AS text,
                   sc.embedding AS embedding,
                   s.*
            FROM semantic_chunks sc
            JOIN sessions s ON s.id = sc.session_id
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY sc.rowid ASC
            LIMIT ?
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(values))
            guard let lastRow = rows.last else {
                return SemanticChunkPage(candidates: [], lastRawRowID: nil)
            }
            let lastRawRowID: Int64
            if let value = lastRow["row_id"] as Int64? {
                lastRawRowID = value
            } else if let value = lastRow["row_id"] as Int? {
                lastRawRowID = Int64(value)
            } else {
                return SemanticChunkPage(candidates: [], lastRawRowID: nil)
            }
            let candidates: [SemanticChunkCandidate] = rows.compactMap { row in
                let rowID: Int64
                if let value = row["row_id"] as Int64? {
                    rowID = value
                } else if let value = row["row_id"] as Int? {
                    rowID = Int64(value)
                } else {
                    return nil
                }
                guard let chunkId = stringValue(row["chunk_id"]),
                      let sessionId = stringValue(row["session_id"]),
                      let text = stringValue(row["text"]),
                      let data = row["embedding"] as Data? else {
                    return nil
                }
                guard let vector = VectorMath.decode(data, expectedCount: dim) else { return nil }
                return SemanticChunkCandidate(
                    rowID: rowID,
                    chunkId: chunkId,
                    sessionId: sessionId,
                    text: text,
                    vector: vector,
                    session: fullSessionObject(from: row)
                )
            }
            return SemanticChunkPage(candidates: candidates, lastRawRowID: lastRawRowID)
        }
    }

    private func searchResultItems(
        sessionIds: [String],
        snippetBySession: [String: String],
        scoreBySession: [String: Double],
        matchType: String,
        fallbackSessionById: [String: OrderedJSONValue]
    ) throws -> [OrderedJSONValue] {
        guard !sessionIds.isEmpty else { return [] }
        let hydrate: (Database) throws -> [String: Row] = { db in
            let placeholders = Array(repeating: "?", count: sessionIds.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT s.*, ls.local_readable_path
                FROM sessions s
                LEFT JOIN session_local_state ls ON ls.session_id = s.id
                WHERE s.id IN (\(placeholders))
                  AND s.hidden_at IS NULL
                  AND s.orphan_status IS NULL
                  AND \(SessionSemanticSearchPolicy.searchableTierSQL)
                """,
                arguments: StatementArguments(sessionIds)
            )
            var map: [String: Row] = [:]
            for row in rows {
                if let id = stringValue(row["id"]) {
                    map[id] = row
                }
            }
            return map
        }
        let rowsById: [String: Row]
        do {
            rowsById = try readImmediate(hydrate)
        } catch let error as DatabaseError
            where error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_LOCKED {
            return sessionIds.compactMap { id in
                guard let session = fallbackSessionById[id] else { return nil }
                return searchResultObject(
                    session: session,
                    snippet: snippetBySession[id] ?? "",
                    matchType: matchType,
                    score: scoreBySession[id] ?? 0
                )
            }
        }
        return sessionIds.compactMap { id in
            guard let row = rowsById[id] else { return nil }
            return searchResultObject(
                row: row,
                snippet: snippetBySession[id] ?? (stringValue(row["summary"]) ?? ""),
                matchType: matchType,
                score: scoreBySession[id] ?? 0
            )
        }
    }

    private func searchResultObject(
        row: Row,
        snippet: String,
        matchType: String,
        score: Double,
        query: String? = nil
    ) -> OrderedJSONValue {
        let renderedSnippet = query.map { keywordSnippet(snippet, query: $0) }
            ?? (redactedSessionMetadata(snippet) ?? "")
        return .object([
            ("session", fullSessionObject(from: row)),
            ("snippet", .string(renderedSnippet)),
            ("matchType", .string(matchType)),
            ("score", .double(score)),
        ])
    }

    private func searchResultObject(
        session: OrderedJSONValue,
        snippet: String,
        matchType: String,
        score: Double
    ) -> OrderedJSONValue {
        .object([
            ("session", session),
            ("snippet", .string(redactedSessionMetadata(snippet) ?? "")),
            ("matchType", .string(matchType)),
            ("score", .double(score)),
        ])
    }

    private func keywordSnippet(_ snippet: String, query: String) -> String {
        let redacted = redactedSessionMetadata(snippet) ?? ""
        let clean = CJKText.removingHighlightMarks(from: redacted)
        return CJKText.highlightedSnippet(content: clean, query: query) ?? clean
    }

    func getContext(
        cwd: String,
        task: String?,
        maxTokens: Int,
        detail: String,
        sortBy: String,
        includeEnvironment: Bool
    ) throws -> String {
        let effectiveMaxTokens = max(1, min(maxTokens, 32_000))
        let maxChars = effectiveMaxTokens * 4
        let projectName = URL(fileURLWithPath: cwd).lastPathComponent
        var sessions = try listContextSessions(projectName: projectName, cwd: cwd)

        if sortBy == "score" {
            sessions.sort { intValue($0["quality_score"]) > intValue($1["quality_score"]) }
        } else {
            sessions.sort { (stringValue($0["activity_time"]) ?? "") > (stringValue($1["activity_time"]) ?? "") }
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

        if let task,
           task.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 {
            let insightRows = (try? searchInsightsFTS(query: task, limit: 5)) ?? []
            for row in insightRows {
                guard let content = stringValue(row["content"]), !content.isEmpty else { continue }
                let line = "[memory] \(TranscriptRedactionPolicy.redact(content))\n"
                if totalChars + line.count > maxChars { break }
                parts.append(line)
                totalChars += line.count
                memoryCount += 1
            }
        }

        for row in sessions {
            guard let summary = redactedSessionMetadata(row["summary"]), !summary.isEmpty else { continue }
            let source = stringValue(row["source"]) ?? "unknown"
            let origin = stringValue(row["origin"])
            let sourceLabel = origin == nil || origin == "local" ? source : "\(origin!)/\(source)"
            let date = toLocalDate(stringValue(row["activity_time"]))
            let line = "[\(sourceLabel)] \(date) — \(summary)\n"
            if totalChars + line.count > maxChars { break }
            parts.append(line)
            totalChars += line.count
            selectedCount += 1
        }

        let memoryNote = memoryCount > 0 ? " + \(memoryCount) memories" : ""
        let footer = "\n— \(selectedCount) sessions\(memoryNote), ~\(Int(ceil(Double(totalChars) / 4.0))) tokens"
        parts.append(footer)

        if includeEnvironment {
            parts.append(try contextEnvironmentSection(detail: detail, maxTokens: effectiveMaxTokens))
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
        // MCP 2025-11-25: structuredContent must be an object root (MCP-001).
        return .object([
            ("aliases", .array(rows.map { row in
                .object([
                    ("alias", .string(row["alias"])),
                    ("canonical", .string(row["canonical"])),
                ])
            })),
        ])
    }

    func resolvedProjectAliases(for project: String) throws -> [String] {
        try resolveProjectAliases([project])
    }

    func totalCostSince(_ since: String) throws -> Double {
        let activityTime = SearchFilterPredicates.activityTimeSQL(alias: "s")
        return try queue.read { db in
            // ARCH-001C: cost KPIs use the shared list-visible population.
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT SUM(c.cost_usd) AS cost
                FROM session_costs c
                JOIN sessions s ON c.session_id = s.id
                WHERE \(SessionVisibilityFilter.listVisibleSQL(alias: "s"))
                  AND \(activityTime) >= ?
                """,
                arguments: [since]
            )
            return doubleValue(row?["cost"])
        }
    }

    func topCostGroupsSince(_ since: String, groupBy: String, limit: Int) throws -> [(key: String, cost: Double, sessions: Int)] {
        let activityTime = SearchFilterPredicates.activityTimeSQL(alias: "s")
        let groupExpr: String
        switch groupBy {
        case "source":
            groupExpr = "s.source"
        case "project":
            groupExpr = "COALESCE(s.project, '(unknown)')"
        default:
            groupExpr = "COALESCE(c.model, '(unknown)')"
        }
        return try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT \(groupExpr) AS key,
                       SUM(c.cost_usd) AS cost,
                       COUNT(*) AS sessions
                FROM session_costs c
                JOIN sessions s ON c.session_id = s.id
                WHERE \(SessionVisibilityFilter.listVisibleSQL(alias: "s"))
                  AND \(activityTime) >= ?
                GROUP BY \(groupExpr)
                HAVING SUM(c.cost_usd) > 0
                ORDER BY cost DESC
                LIMIT ?
                """,
                arguments: [since, limit]
            )
            return rows.map { row in
                (stringValue(row["key"]) ?? "(unknown)", doubleValue(row["cost"]), intValue(row["sessions"]))
            }
        }
    }

    private func contextEnvironmentSection(detail: String, maxTokens: Int) throws -> String {
        let effectiveMaxTokens = max(1, min(maxTokens, 32_000))
        let normalizedDetail: String
        switch detail {
        case "abstract", "overview", "full":
            normalizedDetail = detail
        default:
            normalizedDetail = "full"
        }

        let now = contextNow()
        var localCalendar = Calendar(identifier: .gregorian)
        // L-g: local calendar day, matching get_costs `date(..., 'localtime')`.
        localCalendar.timeZone = contextTimeZone()
        let startOfToday = localCalendar.startOfDay(for: now)
        let startOfTomorrow = localCalendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now

        var rollingWindowCalendar = Calendar(identifier: .gregorian)
        rollingWindowCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let startOfSevenDayWindow = rollingWindowCalendar.date(byAdding: .day, value: -7, to: now) ?? now
        let startOfOneDayWindow = rollingWindowCalendar.date(byAdding: .day, value: -1, to: now) ?? now

        var sections: [String] = []
        if normalizedDetail != "abstract" {
            sections.append("Live sessions: unavailable in Swift MCP stdio runtime")
        }
        let todayCost = optionalEnvironmentValue(label: "costToday") {
            try totalCostBetween(
                start: iso8601Timestamp(startOfToday),
                end: iso8601Timestamp(startOfTomorrow)
            )
        } ?? 0
        if todayCost > 0 {
            sections.append(String(format: "Cost today: $%.2f", locale: Locale(identifier: "en_US_POSIX"), todayCost))
        }

        let alertLimit = normalizedDetail == "overview" ? 5 : 10
        let alerts = optionalEnvironmentValue(label: "alerts") { try activeAlerts(limit: alertLimit) } ?? []
        if !alerts.isEmpty {
            let lines = alerts.map { "  [\($0.severity)] \($0.message)" }.joined(separator: "\n")
            sections.append("Alerts (\(alerts.count)):\n\(lines)")
        }

        if normalizedDetail != "abstract" {
            let itemLimit = normalizedDetail == "overview" ? 5 : 10
            let sevenDaysAgo = iso8601Timestamp(startOfSevenDayWindow)
            let topTools = optionalEnvironmentValue(label: "recentTools") { try topToolsSince(sevenDaysAgo, limit: itemLimit) } ?? []
            if !topTools.isEmpty {
                let lines = topTools.map { "  \($0.name): \($0.callCount) calls" }.joined(separator: "\n")
                sections.append("Top tools (7d):\n\(lines)")
            }

            let changedRepos = optionalEnvironmentValue(label: "gitRepos") { try gitReposWithChanges(limit: itemLimit) } ?? []
            if !changedRepos.isEmpty {
                let lines = changedRepos.map { repo -> String in
                    let branch = repo.branch.map { " (\($0))" } ?? ""
                    return "  \(repo.name)\(branch): \(repo.dirtyCount) dirty, \(repo.unpushedCount) unpushed"
                }.joined(separator: "\n")
                sections.append("Git repos with changes (\(changedRepos.count)):\n\(lines)")
            }

            let hotspots = optionalEnvironmentValue(label: "fileHotspots") { try fileHotspotsSince(sevenDaysAgo, limit: itemLimit) } ?? []
            if !hotspots.isEmpty {
                let lines = hotspots.map { "  \($0.filePath) (\($0.totalEdits) edits, \($0.sessionCount) sessions)" }
                    .joined(separator: "\n")
                sections.append("File hotspots (7d):\n\(lines)")
            }

            let recentErrors = optionalEnvironmentValue(label: "recentErrors") {
                try recentErrorsSince(iso8601Timestamp(startOfOneDayWindow), limit: 5)
            } ?? []
            if !recentErrors.isEmpty {
                let lines = recentErrors.map { "  [\($0.module)] \($0.message) (×\($0.count))" }
                    .joined(separator: "\n")
                sections.append("Recent errors (24h):\n\(lines)")
            }

            let suggestions = optionalEnvironmentValue(label: "costSuggestions") {
                try costSuggestionsSince(sevenDaysAgo, totalSpent: totalCostSince(sevenDaysAgo), limit: 5)
            } ?? []
            if !suggestions.isEmpty {
                let lines = suggestions.map { "  [\($0.severity)] \($0.title)" }.joined(separator: "\n")
                sections.append("Cost suggestions (\(suggestions.count)):\n\(lines)")
            }
        }

        let maxEnvChars = Double(effectiveMaxTokens * 4) * 0.3
        let shouldPruneEnvironment = normalizedDetail != "abstract"
        if shouldPruneEnvironment, sections.joined(separator: "\n").count > Int(maxEnvChars) {
            sections.removeAll { $0.hasPrefix("File hotspots (7d):") }
        }
        if shouldPruneEnvironment, sections.joined(separator: "\n").count > Int(maxEnvChars) {
            sections.removeAll { $0.hasPrefix("Git repos with changes") }
        }
        if shouldPruneEnvironment, sections.joined(separator: "\n").count > Int(maxEnvChars) {
            sections.removeAll { $0.hasPrefix("Recent errors (24h):") }
        }

        guard !sections.isEmpty else { return "" }
        return "\n\n## Environment\n" + sections.joined(separator: "\n")
    }

    func sessionRecord(id: String) throws -> MCPSessionRecord? {
        guard let row = try fetchSessionRow(id: id) else { return nil }
        return makeSessionRecord(from: row)
    }

    func remoteSnapshot(sessionId: String) throws -> (summary: String?, lines: [String])? {
        guard let record = try sessionRecord(id: sessionId) else { return nil }
        guard record.filePath.hasPrefix("remote://") || sessionId.hasPrefix("remote:") else {
            return nil
        }
        let lines = try queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT content FROM sessions_fts WHERE session_id = ? ORDER BY rowid",
                arguments: [sessionId]
            )
        }
        return (record.summary, lines)
    }

    func sessionCost(id: String) throws -> Double? {
        try queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT cost_usd FROM session_costs WHERE session_id = ?",
                arguments: [id]
            )
            guard let row else { return nil }
            return doubleValue(row["cost_usd"])
        }
    }

    private func optionalEnvironmentValue<T>(label: String, _ block: () throws -> T) -> T? {
        do {
            return try block()
        } catch {
            if !isNoSuchTableError(error) {
                writeEnvironmentError(label: label, error: error)
            }
            return nil
        }
    }

    private func totalCostBetween(start: String, end: String) throws -> Double {
        let activityTime = SearchFilterPredicates.activityTimeSQL(alias: "s")
        return try queue.read { db in
            // Filter by the shared end/start activity time, not cost index time,
            // so "Cost today" matches getCosts and totalCostSince.
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT SUM(c.cost_usd) AS cost
                FROM session_costs c
                JOIN sessions s ON c.session_id = s.id
                WHERE \(SessionVisibilityFilter.listVisibleSQL(alias: "s"))
                  AND \(activityTime) >= ? AND \(activityTime) < ?
                """,
                arguments: [start, end]
            )
            return doubleValue(row?["cost"])
        }
    }

    private func activeAlerts(limit: Int) throws -> [(severity: String, message: String)] {
        try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT severity, message
                FROM alerts
                WHERE dismissed_at IS NULL AND resolved_at IS NULL
                ORDER BY CASE severity WHEN 'critical' THEN 0 ELSE 1 END, ts DESC, id DESC
                LIMIT ?
                """,
                arguments: [limit]
            )
            return rows.compactMap { row in
                guard let severity = stringValue(row["severity"]),
                      let message = stringValue(row["message"]),
                      !message.isEmpty
                else {
                    return nil
                }
                return (severity, message)
            }
        }
    }

    private func topToolsSince(_ since: String, limit: Int) throws -> [(name: String, callCount: Int)] {
        let activityTime = SearchFilterPredicates.activityTimeSQL(alias: "s")
        let visibilityConditions = defaultSessionVisibilityConditions(alias: "s")
        return try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT t.tool_name AS name, SUM(t.call_count) AS call_count
                FROM session_tools t
                JOIN sessions s ON s.id = t.session_id
                WHERE \(activityTime) >= ?
                  AND \(visibilityConditions.joined(separator: " AND "))
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

    private func costSuggestionsSince(
        _ since: String,
        totalSpent: Double,
        limit: Int
    ) throws -> [(severity: String, title: String)] {
        guard totalSpent > 0 else { return [] }
        var suggestions: [(severity: String, title: String)] = []

        if let cacheSuggestion = try lowCacheRateSuggestionSince(since) {
            suggestions.append(cacheSuggestion)
        }

        let projectedMonthly = (totalSpent / 7.0) * 30.0
        if projectedMonthly > 50 {
            suggestions.append(("medium", "Monthly pace projects to " + String(format: "$%.2f", projectedMonthly)))
        }

        let topModels = try topCostGroupsSince(since, groupBy: "model", limit: 1)
        if let top = topModels.first, (top.cost / totalSpent) >= 0.5 {
            suggestions.append(("medium", "Model concentration: \(top.key) accounts for \(percent(top.cost / totalSpent * 100)) of spend"))
        }

        let topSources = try topCostGroupsSince(since, groupBy: "source", limit: 1)
        if let top = topSources.first, (top.cost / totalSpent) >= 0.5 {
            suggestions.append(("medium", "Provider concentration: \(top.key) accounts for \(percent(top.cost / totalSpent * 100)) of spend"))
        }

        return Array(suggestions.prefix(limit))
    }

    private func lowCacheRateSuggestionSince(_ since: String) throws -> (severity: String, title: String)? {
        let activityTime = SearchFilterPredicates.activityTimeSQL(alias: "s")
        return try queue.read { db in
            // docs/invariants.md #3: aggregates never include skip-tier sessions.
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT SUM(c.cache_read_tokens) AS cache_read_tokens,
                       SUM(c.input_tokens) AS input_tokens
                FROM session_costs c
                JOIN sessions s ON c.session_id = s.id
                WHERE c.model LIKE 'claude-%' AND \(activityTime) >= ?
                  AND \(SessionVisibilityFilter.listVisibleSQL(alias: "s"))
                """,
                arguments: [since]
            )
            let inputTokens = intValue(row?["input_tokens"])
            guard inputTokens > 0 else { return nil }

            let cacheReadTokens = intValue(row?["cache_read_tokens"])
            let totalInput = inputTokens + cacheReadTokens
            guard totalInput > 0 else { return nil }

            let cacheRate = Double(cacheReadTokens) / Double(totalInput)
            guard cacheRate < 0.3 else { return nil }
            return ("medium", "Low prompt cache utilization")
        }
    }

    private func gitReposWithChanges(
        limit: Int
    ) throws -> [(name: String, branch: String?, dirtyCount: Int, unpushedCount: Int)] {
        try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT name, branch, dirty_count, unpushed_count
                FROM git_repos
                WHERE dirty_count > 0 OR unpushed_count > 0
                ORDER BY dirty_count + unpushed_count DESC, name ASC
                LIMIT ?
                """,
                arguments: [limit]
            )
            return rows.compactMap { row in
                guard let name = stringValue(row["name"]), !name.isEmpty else { return nil }
                return (
                    name,
                    stringValue(row["branch"]),
                    intValue(row["dirty_count"]),
                    intValue(row["unpushed_count"])
                )
            }
        }
    }

    private func fileHotspotsSince(
        _ since: String,
        limit: Int
    ) throws -> [(filePath: String, totalEdits: Int, sessionCount: Int)] {
        let visibilityConditions = defaultSessionVisibilityConditions(alias: "s")
        return try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT sf.file_path AS file_path,
                       SUM(sf.count) AS total_edits,
                       COUNT(DISTINCT sf.session_id) AS session_count
                FROM session_files sf
                WHERE sf.action = 'Edit'
                  AND sf.session_id IN (
                    SELECT s.id
                    FROM sessions s
                    WHERE COALESCE(NULLIF(s.end_time, ''), s.start_time) >= ?
                      AND \(visibilityConditions.joined(separator: " AND "))
                  )
                GROUP BY sf.file_path
                ORDER BY total_edits DESC, session_count DESC, file_path ASC
                LIMIT ?
                """,
                arguments: [since, limit]
            )
            return rows.compactMap { row in
                guard let filePath = stringValue(row["file_path"]), !filePath.isEmpty else { return nil }
                return (filePath, intValue(row["total_edits"]), intValue(row["session_count"]))
            }
        }
    }

    private func recentErrorsSince(
        _ since: String,
        limit: Int
    ) throws -> [(module: String, message: String, count: Int)] {
        try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT module, message, COUNT(*) AS count, MAX(ts) AS last_seen
                FROM logs
                WHERE level = 'error' AND ts >= ?
                GROUP BY module, message
                ORDER BY count DESC, last_seen DESC, module ASC, message ASC
                LIMIT ?
                """,
                arguments: [since, limit]
            )
            return rows.compactMap { row in
                guard let module = stringValue(row["module"]),
                      let message = stringValue(row["message"]),
                      !message.isEmpty
                else {
                    return nil
                }
                return (module, message, intValue(row["count"]))
            }
        }
    }

    /// Active-set SQL fragment for agent-facing insight reads.
    /// Evaluated **outside** any `queue.read` (the probe itself is a read).
    private func supersededFilterSQL(alias: String) -> String {
        ((try? insightsHasLifecycleColumns()) == true) ? " AND \(alias)superseded_by IS NULL" : ""
    }

    private func searchInsightsFTS(
        query: String,
        limit: Int,
        immediate: Bool = false
    ) throws -> [Row] {
        let tokens = CJKText.searchableTerms(query)
        guard !tokens.isEmpty else { return [] }
        let termMatches = CJKText.ftsMatchTerms(tokens)
        var ctes: [String] = []
        var joins: [String] = []
        var values: [DatabaseValueConvertible?] = []
        for (index, token) in tokens.enumerated() {
            let alias = "m\(index)"
            if CJKText.containsCJK(token) || token.count < 3 {
                ctes.append("""
                    \(alias) AS (
                        SELECT insight_id, 0.0 AS rank
                        FROM insights_fts
                        WHERE content LIKE ? ESCAPE '\\'
                        GROUP BY insight_id
                    )
                """)
                values.append("%\(CJKText.escapeLikePattern(token))%")
            } else {
                ctes.append("""
                    \(alias) AS (
                        SELECT insight_id, MIN(rank) AS rank
                        FROM insights_fts
                        WHERE insights_fts MATCH ?
                        GROUP BY insight_id
                    )
                """)
                values.append(termMatches[index])
            }
            if index > 0 {
                joins.append("JOIN \(alias) ON \(alias).insight_id = m0.insight_id")
            }
        }
        values.append(limit)
        return try readRetryingTransientMissingFTS(immediate: immediate) { db in
            let columns = try db.columns(in: "insights")
            let aliasedFilter = columns.contains { $0.name == "superseded_by" }
                ? " AND i.superseded_by IS NULL"
                : ""
            return try Row.fetchAll(
                db,
                sql: """
                WITH \(ctes.joined(separator: ", "))
                SELECT i.*
                FROM m0
                \(joins.joined(separator: " "))
                JOIN insights i ON i.id = m0.insight_id
                WHERE 1 = 1\(aliasedFilter)
                ORDER BY m0.rank, i.created_at DESC
                LIMIT ?
                """,
                arguments: StatementArguments(values)
            )
        }
    }

    private func listInsightsByWing(wing: String?, limit: Int) throws -> [Row] {
        // Probe once before any queue.read — nested GRDB access traps.
        let filter = supersededFilterSQL(alias: "")
        return try queue.read { db in
            if let wing {
                return try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM insights WHERE wing = :wing\(filter) ORDER BY created_at DESC LIMIT :limit",
                    arguments: ["wing": wing, "limit": limit]
                )
            }
            return try Row.fetchAll(
                db,
                sql: "SELECT * FROM insights WHERE 1=1\(filter) ORDER BY created_at DESC LIMIT :limit",
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

    private func fetchSearchableSessionRow(id: String) throws -> Row? {
        try queue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT s.*, ls.local_readable_path
                FROM sessions s
                LEFT JOIN session_local_state ls ON ls.session_id = s.id
                WHERE s.id = ? COLLATE NOCASE
                  AND s.hidden_at IS NULL
                  AND s.orphan_status IS NULL
                  AND \(SessionSemanticSearchPolicy.searchableTierSQL)
                LIMIT 1
                """,
                arguments: [id]
            )
        }
    }

    // MARK: - MCP resources (`@`-mention surface)

    struct ResourceEntry {
        let uri: String
        let name: String
        let description: String
        let mimeType: String
    }

    /// Recent sessions + saved insights exposed as MCP resources so clients
    /// (e.g. Claude Code) can surface them in `@`-mention autocomplete.
    func recentResourceCatalog(sessionLimit: Int, insightLimit: Int) throws -> [ResourceEntry] {
        var entries: [ResourceEntry] = []
        // docs/invariants.md #3: resource browse uses the shared default
        // tier, top-level, and human-driven visibility contract.
        let visibilityConditions = defaultSessionVisibilityConditions(alias: "s")
        let sessionActivity = SearchFilterPredicates.activityTimeSQL(alias: "s")
        let childActivity = SearchFilterPredicates.activityTimeSQL(alias: "resource_child")
        let catalogRecency = """
        MAX(
          \(sessionActivity),
          COALESCE((
            SELECT MAX(\(childActivity))
            FROM sessions resource_child
            WHERE (resource_child.parent_session_id = s.id OR resource_child.suggested_parent_id = s.id)
              AND \(SessionVisibilityFilter.listVisibleSQL(alias: "resource_child"))
              AND resource_child.orphan_status IS NULL
          ), \(sessionActivity))
        )
        """
        let sessions = try queue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT s.*
                FROM sessions s
                WHERE \(visibilityConditions.joined(separator: " AND "))
                ORDER BY \(catalogRecency) DESC
                LIMIT :limit
                """,
                arguments: ["limit": sessionLimit]
            )
        }
        for row in sessions {
            guard let id = stringValue(row["id"]), !id.isEmpty else { continue }
            let title = redactedSessionMetadata(row["generated_title"])
                ?? redactedSessionMetadata(row["summary"])
                ?? id
            let descriptionParts = [stringValue(row["source"]), stringValue(row["project"])]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            entries.append(ResourceEntry(
                uri: "engram://session/\(id)",
                name: String(title.prefix(120)),
                description: descriptionParts.joined(separator: " · "),
                mimeType: "text/markdown"
            ))
        }
        let insights = try listInsightsByWing(wing: nil, limit: insightLimit)
        for row in insights {
            guard let id = stringValue(row["id"]), !id.isEmpty else { continue }
            let content = TranscriptRedactionPolicy.redact(stringValue(row["content"]) ?? "")
            entries.append(ResourceEntry(
                uri: "engram://insight/\(id)",
                name: String(content.prefix(80)),
                description: "Saved insight",
                mimeType: "text/plain"
            ))
        }
        return entries
    }

    /// Plain-text content of a single saved insight, by id.
    func insightContent(id: String) throws -> String? {
        try queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT content FROM insights WHERE id = ? LIMIT 1",
                arguments: [id]
            ).map(TranscriptRedactionPolicy.redact)
        }
    }

    private func listContextSessions(projectName: String, cwd: String) throws -> [Row] {
        let projects = try resolveProjectAliases([projectName])
        let visibilityConditions = defaultSessionVisibilityConditions(alias: "s")
        let activityTime = SearchFilterPredicates.activityTimeSQL(alias: "s")
        return try queue.read { db in
            if !projects.isEmpty {
                let placeholders = Array(repeating: "?", count: projects.count).joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT s.*, \(activityTime) AS activity_time
                    FROM sessions s
                    WHERE \(visibilityConditions.joined(separator: " AND "))
                      AND s.orphan_status IS NULL
                      AND s.project IN (\(placeholders))
                    ORDER BY activity_time DESC
                    LIMIT 50
                    """,
                    arguments: StatementArguments(projects)
                )
                if !rows.isEmpty { return rows }
            }

            return try Row.fetchAll(
                db,
                sql: """
                SELECT s.*, \(activityTime) AS activity_time
                FROM sessions s
                WHERE \(visibilityConditions.joined(separator: " AND "))
                  AND s.orphan_status IS NULL
                  AND s.project = ?
                ORDER BY activity_time DESC
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
        limit: Int,
        immediate: Bool = false
    ) throws -> [(row: Row, snippet: String)] {
        let rawTokens = CJKText.searchableTerms(query)
        guard !rawTokens.isEmpty else { return [] }
        let expandedProjects = try project.map {
            try resolveProjectAliases([$0], immediate: immediate)
        } ?? []
        return try readRetryingTransientMissingFTS(immediate: immediate) { db in
            let termMatches = CJKText.ftsMatchTerms(rawTokens)
            var ctes: [String] = []
            var joins: [String] = []
            var values: [DatabaseValueConvertible?] = []
            for (index, rawTerm) in rawTokens.enumerated() {
                let termMatch = termMatches[index]
                let alias = "m\(index)"
                // mixed-token-1: preserve the service's raw-token
                // classification so quoted short tokens never become broad LIKEs.
                if CJKText.containsCJK(rawTerm) || rawTerm.count < 3 {
                    ctes.append("""
                        \(alias)_hits AS (
                            SELECT rowid, session_id, content,
                                   ROW_NUMBER() OVER (
                                       PARTITION BY session_id
                                       ORDER BY instr(lower(content), lower(?)), rowid
                                   ) AS match_position
                            FROM sessions_fts
                            WHERE content LIKE ? ESCAPE '\\'
                        ),
                        \(alias) AS (
                            SELECT session_id, rowid AS matched_rowid, 0.0 AS rank,
                                   substr(content, MAX(1, instr(lower(content), lower(?)) - 200), 600) AS matched_content
                            FROM \(alias)_hits
                            WHERE match_position = 1
                        )
                    """)
                    values.append(rawTerm)
                    values.append("%\(CJKText.escapeLikePattern(rawTerm))%")
                    values.append(rawTerm)
                } else {
                    ctes.append("""
                        \(alias)_hits AS (
                            SELECT rowid, session_id, rank
                            FROM sessions_fts
                            WHERE sessions_fts MATCH ?
                        ),
                        \(alias) AS (
                            SELECT hits.session_id, MIN(hits.rank) AS rank,
                                   (
                                       SELECT rowid
                                       FROM sessions_fts
                                       WHERE sessions_fts MATCH ?
                                         AND sessions_fts.session_id = hits.session_id
                                       ORDER BY rank, rowid
                                       LIMIT 1
                                   ) AS matched_rowid,
                                   (
                                       SELECT snippet(sessions_fts, 1, '<mark>', '</mark>', '…', 64)
                                       FROM sessions_fts
                                       WHERE sessions_fts MATCH ?
                                         AND sessions_fts.session_id = hits.session_id
                                       ORDER BY rank, rowid
                                       LIMIT 1
                                   ) AS matched_content
                            FROM \(alias)_hits hits
                            GROUP BY hits.session_id
                        )
                    """)
                    values.append(termMatch)
                    values.append(termMatch)
                    values.append(termMatch)
                }
                if index > 0 {
                    joins.append("JOIN \(alias) ON \(alias).session_id = m0.session_id")
                }
            }
            var conditions = [
                "s.hidden_at IS NULL",
                "s.orphan_status IS NULL",
                SessionSemanticSearchPolicy.searchableTierSQL,
            ]
            Self.appendSearchFilterPredicates(
                source: source,
                expandedProjects: expandedProjects,
                since: since,
                conditions: &conditions,
                values: &values
            )
            values.append(limit)

            let matchedContentExpression = rawTokens.indices.dropFirst().reduce(
                "COALESCE(m0.matched_content, '')"
            ) { expression, index in
                let priorRowIDs = rawTokens.indices.prefix(index)
                    .map { "m\($0).matched_rowid" }
                    .joined(separator: ", ")
                return """
                    \(expression) || CASE
                      WHEN NULLIF(m\(index).matched_content, '') IS NULL THEN ''
                      WHEN m\(index).matched_rowid IN (\(priorRowIDs)) THEN ''
                      ELSE '\n…\n' || m\(index).matched_content
                    END
                    """
            }
            let sql = """
            WITH \(ctes.joined(separator: ", "))
            SELECT
              s.*,
              ls.local_readable_path,
              \(matchedContentExpression) AS matched_content,
              m0.rank
            FROM m0
            \(joins.joined(separator: " "))
            JOIN sessions s ON s.id = m0.session_id
            LEFT JOIN session_local_state ls ON ls.session_id = s.id
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY m0.rank, s.start_time DESC
            LIMIT ?
            """

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(values))
            return rows.map { row in
                (row, stringValue(row["matched_content"]) ?? "")
            }
        }
    }

    /// H2: CJK/short-query LIKE fallback (parity with app Database.search).
    private func keywordSearchLike(
        query: String,
        source: String?,
        expandedProjects: [String],
        since: String?,
        limit: Int,
        immediate: Bool = false
    ) throws -> [(row: Row, snippet: String)] {
        try readRetryingTransientMissingFTS(immediate: immediate) { db in
            var conditions = [
                "f.content LIKE ? ESCAPE '\\'",
                "s.hidden_at IS NULL",
                "s.orphan_status IS NULL",
                SessionSemanticSearchPolicy.searchableTierSQL,
            ]
            let pattern = "%\(CJKText.escapeLikePattern(query))%"
            var values: [DatabaseValueConvertible?] = [query, pattern]

            Self.appendSearchFilterPredicates(
                source: source,
                expandedProjects: expandedProjects,
                since: since,
                conditions: &conditions,
                values: &values
            )
            values.append(limit)

            let sql = """
            SELECT
              s.*,
              ls.local_readable_path,
              engram_redacted_keyword_snippet(f.content, ?) AS snippet
            FROM sessions_fts f
            JOIN sessions s ON s.id = f.session_id
            LEFT JOIN session_local_state ls ON ls.session_id = s.id
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY s.start_time DESC
            LIMIT ?
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(values))
            return rows.map { row in
                (row, stringValue(row["snippet"]) ?? "")
            }
        }
    }

    private static func appendSearchFilterPredicates(
        source: String?,
        expandedProjects: [String],
        since: String?,
        conditions: inout [String],
        values: inout [DatabaseValueConvertible?]
    ) {
        let clauses = SearchFilterPredicates.clauses(
            sources: source.map { [$0] } ?? [],
            projects: expandedProjects,
            since: since
        )
        for clause in clauses {
            conditions.append(clause.sql)
            for binding in clause.bindings {
                values.append(binding)
            }
        }
    }

    private func readRetryingTransientMissingFTS<T>(
        immediate: Bool = false,
        _ block: (Database) throws -> T
    ) throws -> T {
        let maxAttempts = 10
        var attempt = 0
        while true {
            attempt += 1
            do {
                if immediate {
                    return try readImmediate(block)
                }
                return try queue.read(block)
            } catch {
                guard isTransientMissingFTSTable(error), attempt < maxAttempts else { throw error }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func isTransientMissingFTSTable(_ error: Error) -> Bool {
        let message = String(describing: error)
        return message.contains("no such table: sessions_fts")
            || message.contains("no such table: insights_fts")
    }

    private func resolveProjectAliases(
        _ projects: [String],
        immediate: Bool = false
    ) throws -> [String] {
        guard !projects.isEmpty else { return projects }
        let read: ((Database) throws -> [String]) = { db in
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
        if immediate {
            return try readImmediate(read)
        }
        return try queue.read(read)
    }
}

private func listSessionObject(from row: Row) -> OrderedJSONValue {
    let startTime = toLocalDateTime(stringValue(row["start_time"]))
    let endTime = toLocalDateTime(stringValue(row["end_time"]))
    let entries: [(String, OrderedJSONValue)] = [
        ("id", .string(stringValue(row["id"]) ?? "")),
        ("source", .string(stringValue(row["source"]) ?? "unknown")),
        ("origin", valueOrNull(stringValue(row["origin"]))),
        ("startTime", .string(startTime)),
        ("endTime", .string(endTime)),
        ("cwd", .string(stringValue(row["cwd"]) ?? "")),
        ("project", valueOrNull(stringValue(row["project"]))),
        ("model", valueOrNull(stringValue(row["model"]))),
        ("messageCount", .int(intValue(row["message_count"]))),
        ("userMessageCount", .int(intValue(row["user_message_count"]))),
        ("summary", valueOrNull(redactedSessionMetadata(row["summary"]))),
        ("tier", valueOrNull(stringValue(row["tier"]))),
        ("parentSessionId", valueOrNull(stringValue(row["parent_session_id"]))),
    ]
    return .object(entries)
}

private func fullSessionObject(from row: Row) -> OrderedJSONValue {
    makeSessionRecord(from: row).orderedJSONValue
}

private func costSummaryObject(from row: Row) -> OrderedJSONValue {
    let entries: [(String, OrderedJSONValue)] = [
        ("key", valueOrNull(stringValue(row["key"]))),
        ("inputTokens", .int(intValue(row["inputTokens"]))),
        ("outputTokens", .int(intValue(row["outputTokens"]))),
        ("cacheReadTokens", .int(intValue(row["cacheReadTokens"]))),
        ("cacheCreationTokens", .int(intValue(row["cacheCreationTokens"]))),
        ("costUsd", .double(doubleValue(row["costUsd"]))),
        ("sessionCount", .int(intValue(row["sessionCount"]))),
    ]
    return .object(entries)
}

private func toolAnalyticsObject(from row: Row, groupBy: String) -> OrderedJSONValue {
    var entries: [(String, OrderedJSONValue)] = [
        ("key", valueOrNull(stringValue(row["key"]))),
        ("callCount", .int(intValue(row["callCount"]))),
    ]
    if groupBy == "session" {
        entries.append(("label", valueOrNull(redactedSessionMetadata(row["label"]))))
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
        ("id", .string(stringValue(row["id"]) ?? "")),
        ("oldPath", .string(stringValue(row["old_path"]) ?? "")),
        ("newPath", .string(stringValue(row["new_path"]) ?? "")),
        ("oldBasename", .string(stringValue(row["old_basename"]) ?? "")),
        ("newBasename", .string(stringValue(row["new_basename"]) ?? "")),
        ("state", .string(stringValue(row["state"]) ?? "")),
        ("filesPatched", .int(intValue(row["files_patched"]))),
        ("occurrences", .int(intValue(row["occurrences"]))),
        ("sessionsUpdated", .int(intValue(row["sessions_updated"]))),
        ("aliasCreated", .bool(boolValue(row["alias_created"]))),
        ("ccDirRenamed", .bool(boolValue(row["cc_dir_renamed"]))),
        ("startedAt", .string(stringValue(row["started_at"]) ?? "")),
        ("finishedAt", valueOrNull(stringValue(row["finished_at"]))),
        ("dryRun", .bool(boolValue(row["dry_run"]))),
        ("rolledBackOf", valueOrNull(stringValue(row["rolled_back_of"]))),
        ("auditNote", valueOrNull(stringValue(row["audit_note"]))),
        ("archived", .bool(boolValue(row["archived"]))),
        ("actor", .string(stringValue(row["actor"]) ?? "")),
        ("detail", detailJSONValue(from: row["detail"])),
        ("error", valueOrNull(stringValue(row["error"]))),
    ]
    return .object(entries)
}

private func memoryObject(from row: Row, distance: Double) -> OrderedJSONValue {
    // Missing/NULL insight_type is treated as semantic (same as the filter path).
    let type = stringValue(row["insight_type"]) ?? "semantic"
    return .object([
        ("id", .string(stringValue(row["id"]) ?? "")),
        ("content", .string(TranscriptRedactionPolicy.redact(stringValue(row["content"]) ?? ""))),
        ("wing", valueOrNull(stringValue(row["wing"]))),
        ("room", valueOrNull(stringValue(row["room"]))),
        ("importance", .int(intValue(row["importance"]))),
        ("distance", .double(distance)),
        ("type", .string(type)),
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
        summary: redactedSessionMetadata(row["summary"]),
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

private func redactedSessionMetadata(_ raw: DatabaseValueConvertible?) -> String? {
    guard let value = stringValue(raw) else { return nil }
    return TranscriptRedactionPolicy.redact(value)
}

private func redactedKeywordSnippet(content: String, query: String) -> String {
    let redacted = TranscriptRedactionPolicy.redact(content)
    let highlighted = CJKText.cjkHighlightedSnippet(content: redacted, query: query, window: 200)
        ?? CJKText.cjkHighlightedSnippet(
            content: redacted,
            query: TranscriptRedactionPolicy.redactionToken,
            window: 200
        )
        ?? redacted
    return String(highlighted.prefix(600))
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

/// Process-local zone for MCP calendar math and date formatting.
/// Honors `TZ` (IANA identifier) so executable tests can pin Asia/Shanghai vs UTC.
func contextTimeZone() -> TimeZone {
    if let configured = ProcessInfo.processInfo.environment["TZ"],
       let timeZone = TimeZone(identifier: configured) {
        return timeZone
    }
    return .autoupdatingCurrent
}

/// Shared clock for MCP tools. Injectable via `ENGRAM_MCP_NOW` (ISO-8601).
/// Module-internal (not `private`) so tools like `MCPInsightsTool` can share it
/// for honest window-day math (row 3 / mcp-cost Part A).
func contextNow() -> Date {
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

private func percent(_ value: Double) -> String {
    String(format: "%.0f%%", value)
}

private func isNoSuchTableError(_ error: Error) -> Bool {
    String(describing: error).contains("no such table")
}

private func writeEnvironmentError(label: String, error: Error) {
    let message = "[get_context] \(label) error: \(error)\n"
    if let data = message.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
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
    output.timeZone = contextTimeZone()
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
    output.timeZone = contextTimeZone()
    output.dateFormat = "yyyy-MM-dd"
    return output.string(from: date)
}

private func isUUID(_ value: String) -> Bool {
    value.range(
        of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
        options: [.regularExpression, .caseInsensitive]
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
            return "Anomaly — log says committed but src still exists. Investigate manually; consider `project_undo` with this migration id."
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
            return "Move seems to have actually succeeded; DB log did not catch up. Use `project_recover` to inspect the recorded paths. If needed, move the directory back manually, then retry with `project_move`; do not edit migration_log directly."
        }
        return "Neither path exists — project directory contents are missing. Engram does not back up project directories; restore from your own file backup (for example Time Machine), then use `project_list_migrations`/`project_recover` to inspect migration_log old_path/new_path."
    }
    if state == "fs_done" {
        if !oldExists && newExists {
            return "FS move succeeded; DB commit failed mid-way. Restart the Engram service once so startup recovery can finish the idempotent rewrite. If it remains fs_done, inspect service logs and use `project_review` with old_path/new_path; do not edit migration_log directly."
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
            return "FS move completed but DB commit failed and compensation did not reverse the FS. Manually move new → old, inspect with `project_review`, then retry through `project_move`; do not edit migration_log directly."
        }
        if oldExists && newExists {
            return "Both paths exist — compensation ran partially. Inspect, then use `project_move` (or manual mv) to reach a consistent state."
        }
        return "Neither path exists — likely data loss. Engram does not back up project directories; restore from your own file backup (for example Time Machine), then use `project_list_migrations`/`project_recover` to inspect migration_log old_path/new_path."
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


/// Indexes MCP search result objects by nested `session.id` (not positional zip).
enum MCPSearchResultIndex {
    static func bySessionId(_ items: [OrderedJSONValue]) -> [String: OrderedJSONValue] {
        var map: [String: OrderedJSONValue] = [:]
        map.reserveCapacity(items.count)
        for item in items {
            guard case .object(let entries) = item,
                  let sessionValue = entries.first(where: { $0.0 == "session" })?.1,
                  case .object(let sessionEntries) = sessionValue,
                  let idValue = sessionEntries.first(where: { $0.0 == "id" })?.1,
                  case .string(let id) = idValue else {
                continue
            }
            map[id] = item
        }
        return map
    }
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
                    result.append(try parseUnicodeEscape())
                default:
                    throw ParserError.invalidEscape
                }
            } else {
                result.append(character)
            }
        }
        throw ParserError.unexpectedEOF
    }

    private mutating func parseUnicodeEscape() throws -> String {
        let value = try readUnicodeEscapeValue()
        if (0xD800...0xDBFF).contains(value) {
            guard index < text.endIndex, text[index] == "\\" else {
                throw ParserError.invalidEscape
            }
            advance()
            guard index < text.endIndex, text[index] == "u" else {
                throw ParserError.invalidEscape
            }
            advance()
            let low = try readUnicodeEscapeValue()
            guard (0xDC00...0xDFFF).contains(low) else {
                throw ParserError.invalidEscape
            }
            let scalarValue = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
            guard let scalar = UnicodeScalar(scalarValue) else {
                throw ParserError.invalidEscape
            }
            return String(Character(scalar))
        }
        if (0xDC00...0xDFFF).contains(value) {
            throw ParserError.invalidEscape
        }
        guard let scalar = UnicodeScalar(value) else {
            throw ParserError.invalidEscape
        }
        return String(Character(scalar))
    }

    private mutating func readUnicodeEscapeValue() throws -> UInt32 {
        let hex = try read(length: 4)
        guard let value = UInt32(hex, radix: 16) else {
            throw ParserError.invalidEscape
        }
        return value
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
