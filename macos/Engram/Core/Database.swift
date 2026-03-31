// macos/Engram/Core/Database.swift
import Foundation
import GRDB
import Observation

enum DatabaseError: Error {
    case notOpen
}

enum SessionSort: String {
    case createdDesc = "start_time DESC"
    case createdAsc  = "start_time ASC"
    case updatedDesc = "COALESCE(end_time, start_time) DESC"
    case updatedAsc  = "COALESCE(end_time, start_time) ASC"
}

enum GroupingMode: String, CaseIterable {
    case project = "Project"
    case source = "Source"
}

/// Shared sub-agent filter builder — eliminates 6x duplication across query methods
private func subAgentFilterClause(_ subAgent: Bool) -> String {
    subAgent
        ? "AND (agent_role IS NOT NULL OR file_path LIKE '%/subagents/%')"
        : "AND (tier IS NULL OR tier != 'skip')"
}

@MainActor
@Observable
final class DatabaseManager {
    @ObservationIgnored nonisolated(unsafe) private let dbPath: String
    @ObservationIgnored nonisolated(unsafe) private var pool: DatabasePool?
    @ObservationIgnored private var writerPool: DatabasePool?

    /// File path to the SQLite database (nonisolated for background FileManager access)
    nonisolated var path: String { dbPath }

    // Thread-safe read accessor — GRDB DatabasePool.read is internally thread-safe.
    // pool is set once in open() and never mutated again, so nonisolated access is safe.
    nonisolated func readInBackground<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        guard let pool = pool else { throw DatabaseError.notOpen }
        return try pool.read(block)
    }

    init(path: String? = nil) {
        self.dbPath = path ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".engram/index.sqlite").path
    }

    func open() throws {
        // Single pool for both reads and writes
        // (read-only DatabasePool can't reliably access WAL-mode DBs written by daemon)
        pool = try DatabasePool(path: dbPath)
        writerPool = pool
        try writerPool!.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS favorites (
                    session_id TEXT PRIMARY KEY,
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS tags (
                    session_id TEXT NOT NULL,
                    tag        TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    PRIMARY KEY (session_id, tag)
                );
            """)
            // Idempotent column additions for hide/rename
            let existing = try Set(Row.fetchAll(db, sql: "PRAGMA table_info(sessions)").map {
                $0["name"] as String
            })
            for (name, def) in [("hidden_at", "TEXT"), ("custom_name", "TEXT")] {
                if !existing.contains(name) {
                    try db.execute(sql: "ALTER TABLE sessions ADD COLUMN \(name) \(def)")
                }
            }
        }
    }

    // MARK: - list_sessions
    func listSessions(
        sources: Set<String> = [],   // empty = all
        projects: Set<String> = [],  // empty = all
        since: String? = nil,
        subAgent: Bool? = nil,       // nil=all, true=only sub-agents, false=hide sub-agents
        sort: SessionSort = .createdDesc,
        limit: Int = 200,
        offset: Int = 0
    ) throws -> [Session] {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            var parts = ["SELECT * FROM sessions WHERE hidden_at IS NULL"]
            var args: [DatabaseValueConvertible] = []
            if !sources.isEmpty {
                let ph = sources.map { _ in "?" }.joined(separator: ", ")
                parts.append("AND source IN (\(ph))")
                sources.forEach { args.append($0) }
            }
            if !projects.isEmpty {
                let ph = projects.map { _ in "?" }.joined(separator: ", ")
                parts.append("AND project IN (\(ph))")
                projects.forEach { args.append($0) }
            }
            if let since { parts.append("AND start_time >= ?"); args.append(since) }
            if let subAgent {
                parts.append(subAgentFilterClause(subAgent))
            }
            parts.append("ORDER BY \(sort.rawValue) LIMIT ? OFFSET ?")
            args.append(limit); args.append(offset)
            return try Session.fetchAll(db, sql: parts.joined(separator: " "),
                                        arguments: StatementArguments(args))
        }
    }

    // MARK: - list projects
    func listProjects() throws -> [String] {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT project FROM sessions
                WHERE project IS NOT NULL AND hidden_at IS NULL
                ORDER BY project
            """)
        }
    }

    func countsBySource() throws -> [String: Int] {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT source, COUNT(*) as n FROM sessions WHERE hidden_at IS NULL GROUP BY source
            """)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["source"] as String, $0["n"] as Int) })
        }
    }

    struct SourceStat {
        let source: String
        let count: Int
        let latestIndexed: String
    }

    nonisolated func sourceStats() throws -> [SourceStat] {
        try readInBackground { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT source, COUNT(*) as count, MAX(indexed_at) as latest_indexed
                FROM sessions WHERE hidden_at IS NULL
                GROUP BY source
            """)
            return rows.map { row in
                SourceStat(
                    source: row["source"],
                    count: row["count"],
                    latestIndexed: (row["latest_indexed"] as String?) ?? ""
                )
            }
        }
    }

    func countsByProject() throws -> [String: Int] {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT project, COUNT(*) as n FROM sessions
                WHERE project IS NOT NULL AND hidden_at IS NULL GROUP BY project
            """)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["project"] as String, $0["n"] as Int) })
        }
    }

    func listSessionsForProject(_ project: String?, subAgent: Bool? = nil, limit: Int = 100) throws -> [Session] {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            var parts: [String]
            var args: [DatabaseValueConvertible]
            if let project {
                parts = ["SELECT * FROM sessions WHERE hidden_at IS NULL AND project = ?"]
                args  = [project]
            } else {
                parts = ["SELECT * FROM sessions WHERE hidden_at IS NULL AND project IS NULL"]
                args  = []
            }
            if let subAgent {
                parts.append(subAgentFilterClause(subAgent))
            }
            parts.append("ORDER BY start_time DESC LIMIT ?")
            args.append(limit)
            return try Session.fetchAll(db, sql: parts.joined(separator: " "),
                                        arguments: StatementArguments(args))
        }
    }

    func getSession(id: String) throws -> Session? {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            try Session.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [id])
        }
    }

    func countSessions(
        sources: Set<String> = [],
        projects: Set<String> = [],
        subAgent: Bool? = nil
    ) throws -> Int {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            var parts = ["SELECT COUNT(*) FROM sessions WHERE hidden_at IS NULL"]
            var args: [DatabaseValueConvertible] = []
            if !sources.isEmpty {
                let ph = sources.map { _ in "?" }.joined(separator: ", ")
                parts.append("AND source IN (\(ph))")
                sources.forEach { args.append($0) }
            }
            if !projects.isEmpty {
                let ph = projects.map { _ in "?" }.joined(separator: ", ")
                parts.append("AND project IN (\(ph))")
                projects.forEach { args.append($0) }
            }
            if let subAgent {
                parts.append(subAgentFilterClause(subAgent))
            }
            parts.append("GROUP BY group_key ORDER BY sort_value \(orderDir)")

            let rows = try Row.fetchAll(db, sql: parts.joined(separator: " "),
                                        arguments: StatementArguments(args))
            return rows.map { (
                key: $0["group_key"] as String? ?? "(unknown)",
                count: $0["count"] as Int,
                lastUpdated: $0["sort_value"] as String
            ) }
        }
    }

    /// Get sessions within a specific group
    func listSessionsInGroup(
        by mode: GroupingMode,
        key: String,
        sources: Set<String> = [],
        projects: Set<String> = [],
        subAgent: Bool? = nil,
        sort: SessionSort = .createdDesc,
        limit: Int = 100
    ) throws -> [Session] {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            let groupColumn = mode == .project ? "project" : "source"
            var parts = ["SELECT * FROM sessions WHERE hidden_at IS NULL"]
            var args: [DatabaseValueConvertible] = []

            // Group filter
            if key == "(unknown)" {
                parts.append("AND \(groupColumn) IS NULL")
            } else {
                parts.append("AND \(groupColumn) = ?")
                args.append(key)
            }

            // Additional filters
            if !sources.isEmpty {
                let ph = sources.map { _ in "?" }.joined(separator: ", ")
                parts.append("AND source IN (\(ph))")
                sources.forEach { args.append($0) }
            }
            if !projects.isEmpty {
                let ph = projects.map { _ in "?" }.joined(separator: ", ")
                parts.append("AND project IN (\(ph))")
                projects.forEach { args.append($0) }
            }
            if let subAgent {
                parts.append(subAgentFilterClause(subAgent))
            }

            parts.append("ORDER BY \(sort.rawValue) LIMIT ?")
            args.append(limit)

            return try Session.fetchAll(db, sql: parts.joined(separator: " "),
                                        arguments: StatementArguments(args))
        }
    }

    // MARK: - Dashboard Queries

    struct KPIStats {
        let sessions: Int
        let sources: Int
        let messages: Int
        let projects: Int
    }

    func countSessionsSince(_ since: String) throws -> Int {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) as n FROM sessions
                WHERE hidden_at IS NULL AND start_time >= ?
            """, arguments: [since])!
            return row["n"] as Int
        }
    }

    func kpiStats() throws -> KPIStats {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    COUNT(*) as sessions,
                    COUNT(DISTINCT source) as sources,
                    SUM(message_count) as messages,
                    COUNT(DISTINCT project) as projects
                FROM sessions WHERE hidden_at IS NULL
            """)!
            return KPIStats(
                sessions: row["sessions"],
                sources: row["sources"],
                messages: row["messages"] ?? 0,
                projects: row["projects"]
            )
        }
    }

    func dailyActivity(days: Int = 30) throws -> [(date: String, count: Int)] {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DATE(start_time) as day, COUNT(*) as count
                FROM sessions
                WHERE hidden_at IS NULL
                  AND start_time >= DATE('now', '-\(days) days')
                GROUP BY day ORDER BY day
            """)
            return rows.map { (date: $0["day"] as String, count: $0["count"] as Int) }
        }
    }

    func hourlyActivity() throws -> [Int] {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT CAST(strftime('%H', start_time, 'localtime') AS INTEGER) as hour,
                       COUNT(*) as count
                FROM sessions
                WHERE hidden_at IS NULL
                GROUP BY hour ORDER BY hour
            """)
            var hours = Array(repeating: 0, count: 24)
            for row in rows {
                let h: Int = row["hour"]
                let c: Int = row["count"]
                if h >= 0 && h < 24 { hours[h] = c }
            }
            return hours
        }
    }

    func sourceDistribution() throws -> [(source: String, count: Int)] {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT source, COUNT(*) as count
                FROM sessions WHERE hidden_at IS NULL
                GROUP BY source ORDER BY count DESC
            """)
            return rows.map { (source: $0["source"] as String, count: $0["count"] as Int) }
        }
    }

    func tierDistribution() throws -> (premium: Int, normal: Int, lite: Int, skip: Int) {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT COALESCE(tier, 'normal') as t, COUNT(*) as count
                FROM sessions WHERE hidden_at IS NULL
                GROUP BY t
            """)
            var result = (premium: 0, normal: 0, lite: 0, skip: 0)
            for row in rows {
                let t: String = row["t"]
                let c: Int = row["count"]
                switch t {
                case "premium": result.premium = c
                case "normal":  result.normal = c
                case "lite":    result.lite = c
                case "skip":    result.skip = c
                default:        result.normal += c
                }
            }
            return result
        }
    }

    func recentSessions(limit: Int = 8) throws -> [Session] {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            try Session.fetchAll(db, sql: """
                SELECT * FROM sessions
                WHERE hidden_at IS NULL AND (tier IS NULL OR tier != 'skip')
                ORDER BY start_time DESC LIMIT ?
            """, arguments: [limit])
        }
    }

    func sessionTimeline(days: Int = 30) throws -> [(date: String, sessions: [Session])] {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            let sessions = try Session.fetchAll(db, sql: """
                SELECT * FROM sessions
                WHERE hidden_at IS NULL
                  AND start_time >= DATE('now', '-\(days) days')
                  AND (tier IS NULL OR tier != 'skip')
                ORDER BY start_time DESC
            """)
            let grouped = Dictionary(grouping: sessions) { String($0.startTime.prefix(10)) }
            return grouped.sorted { $0.key > $1.key }
                .map { (date: $0.key, sessions: $0.value) }
        }
    }

    struct ProjectGroup: Identifiable {
        let id: String
        let project: String
        let sessionCount: Int
        let lastActive: String
        let sessions: [Session]
    }

    // MARK: - Git Repos

    func listGitRepos() throws -> [GitRepo] {
        try pool!.read { db in
            try GitRepo.fetchAll(db, sql: "SELECT * FROM git_repos ORDER BY last_commit_at DESC")
        }
    }

    /// Returns session counts for the last 7 days (index 0 = 6 days ago, index 6 = today)
    /// for sessions whose cwd starts with repoPath.
    func sparklineData(for repoPath: String) throws -> [Int] {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT date(start_time) as day, COUNT(*) as n
                FROM sessions
                WHERE hidden_at IS NULL
                  AND (tier IS NULL OR tier != 'skip')
                  AND cwd LIKE ?
                  AND start_time >= date('now', '-6 days')
                GROUP BY day
            """, arguments: ["\(repoPath)%"])
            var counts = [Int](repeating: 0, count: 7)
            let today = Calendar.current.startOfDay(for: Date())
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            for row in rows {
                guard let dayStr = row["day"] as String?,
                      let date = fmt.date(from: dayStr) else { continue }
                let daysAgo = Calendar.current.dateComponents([.day], from: date, to: today).day ?? 99
                if daysAgo >= 0 && daysAgo < 7 {
                    counts[6 - daysAgo] = row["n"]
                }
            }
            return counts
        }
    }

    func listSessionsByProject(limit: Int = 100) throws -> [ProjectGroup] {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            let sessions = try Session.fetchAll(db, sql: """
                SELECT * FROM sessions
                WHERE hidden_at IS NULL AND project IS NOT NULL
                  AND (tier IS NULL OR tier != 'skip')
                ORDER BY start_time DESC
                LIMIT ?
            """, arguments: [limit * 10])
            let grouped = Dictionary(grouping: sessions) { $0.project ?? "(unknown)" }
            return grouped.map { project, sessions in
                ProjectGroup(
                    id: project,
                    project: project,
                    sessionCount: sessions.count,
                    lastActive: sessions.first?.startTime ?? "",
                    sessions: Array(sessions.prefix(limit))
                )
            }
            .sorted { $0.lastActive > $1.lastActive }
        }
    }

    // MARK: - Observability: Logs

    func fetchLogs(level: String, module: String, limit: Int) throws -> LogQueryResult {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            // Fetch available modules
            let modules = try String.fetchAll(db, sql: """
                SELECT DISTINCT module FROM logs ORDER BY module
            """)

            // Build filtered query
            var parts = ["SELECT * FROM logs WHERE 1=1"]
            var args: [DatabaseValueConvertible] = []
            if level != "All" {
                parts.append("AND level = ?")
                args.append(level)
            }
            if module != "All" {
                parts.append("AND module = ?")
                args.append(module)
            }
            parts.append("ORDER BY ts DESC LIMIT ?")
            args.append(limit)

            let rows = try Row.fetchAll(db, sql: parts.joined(separator: " "),
                                        arguments: StatementArguments(args))
            let entries = rows.map { row in
                LogEntry(
                    id: row["id"],
                    ts: row["ts"],
                    level: row["level"],
                    module: row["module"],
                    message: row["message"],
                    traceId: row["trace_id"],
                    source: row["source"],
                    errorName: row["error_name"],
                    errorMessage: row["error_message"]
                )
            }
            return LogQueryResult(entries: entries, modules: modules)
        }
    }

    // MARK: - Observability: Errors

    func countErrors24h() throws -> Int {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM logs
                WHERE level = 'error'
                  AND ts >= datetime('now', '-24 hours')
            """) ?? 0
        }
    }

    func errorsByModule24h() throws -> [(module: String, count: Int)] {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT module, COUNT(*) as count FROM logs
                WHERE level = 'error'
                  AND ts >= datetime('now', '-24 hours')
                GROUP BY module
                ORDER BY count DESC
            """)
            return rows.map { (module: $0["module"] as String, count: $0["count"] as Int) }
        }
    }

    func recentErrors(limit: Int) throws -> [LogEntry] {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM logs
                WHERE level IN ('error', 'warn')
                ORDER BY ts DESC LIMIT ?
            """, arguments: [limit])
            return rows.map { row in
                LogEntry(
                    id: row["id"],
                    ts: row["ts"],
                    level: row["level"],
                    module: row["module"],
                    message: row["message"],
                    traceId: row["trace_id"],
                    source: row["source"],
                    errorName: row["error_name"],
                    errorMessage: row["error_message"]
                )
            }
        }
    }

    // MARK: - Observability: Traces

    func fetchTraces(nameFilter: String, limit: Int) throws -> [TraceEntry] {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            var parts = ["SELECT * FROM traces WHERE 1=1"]
            var args: [DatabaseValueConvertible] = []
            if !nameFilter.isEmpty {
                parts.append("AND name LIKE ?")
                args.append("%\(nameFilter)%")
            }
            parts.append("ORDER BY start_ts DESC LIMIT ?")
            args.append(limit)

            let rows = try Row.fetchAll(db, sql: parts.joined(separator: " "),
                                        arguments: StatementArguments(args))
            return rows.map { row in
                TraceEntry(
                    id: row["id"],
                    traceId: row["trace_id"],
                    spanId: row["span_id"],
                    parentSpanId: row["parent_span_id"],
                    name: row["name"],
                    module: row["module"],
                    startTs: row["start_ts"],
                    endTs: row["end_ts"],
                    durationMs: row["duration_ms"],
                    status: row["status"],
                    attributes: row["attributes"],
                    source: row["source"]
                )
            }
        }
    }

    func slowTraces(minDurationMs: Int, limit: Int) throws -> [TraceEntry] {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM traces
                WHERE duration_ms > ?
                ORDER BY duration_ms DESC
                LIMIT ?
            """, arguments: [minDurationMs, limit])
            return rows.map { row in
                TraceEntry(
                    id: row["id"],
                    traceId: row["trace_id"],
                    spanId: row["span_id"],
                    parentSpanId: row["parent_span_id"],
                    name: row["name"],
                    module: row["module"],
                    startTs: row["start_ts"],
                    endTs: row["end_ts"],
                    durationMs: row["duration_ms"],
                    status: row["status"],
                    attributes: row["attributes"],
                    source: row["source"]
                )
            }
        }
    }

    // MARK: - Observability: Metrics

    func recentHourlyMetrics(limit: Int) throws -> [HourlyMetric] {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM metrics_hourly
                ORDER BY hour DESC
                LIMIT ?
            """, arguments: [limit])
            return rows.map { row in
                HourlyMetric(
                    id: row["id"],
                    name: row["name"],
                    type: row["type"],
                    hour: row["hour"],
                    count: row["count"],
                    sum: row["sum"],
                    min: row["min"],
                    max: row["max"],
                    p95: row["p95"]
                )
            }
        }
    }

    // MARK: - Observability: Health

    // MARK: - Observability: Log Observation

    /// Start a ValueObservation on the logs table. Returns a cancellable that must
    /// be retained by the caller. The onChange closure fires on the main actor whenever
    /// the logs table changes (insert / update / delete).
    nonisolated func observeLogs(
        level: String,
        module: String,
        limit: Int,
        onError: @escaping @Sendable (Error) -> Void,
        onChange: @escaping @Sendable (LogQueryResult) -> Void
    ) throws -> AnyDatabaseCancellable {
        guard let pool else { throw DatabaseError.notOpen }

        let observation = ValueObservation.tracking { db -> LogQueryResult in
            // Fetch available modules
            let modules = try String.fetchAll(db, sql: """
                SELECT DISTINCT module FROM logs ORDER BY module
            """)

            // Build filtered query
            var parts = ["SELECT * FROM logs WHERE 1=1"]
            var args: [DatabaseValueConvertible] = []
            if level != "All" {
                parts.append("AND level = ?")
                args.append(level)
            }
            if module != "All" {
                parts.append("AND module = ?")
                args.append(module)
            }
            parts.append("ORDER BY ts DESC LIMIT ?")
            args.append(limit)

            let rows = try Row.fetchAll(db, sql: parts.joined(separator: " "),
                                        arguments: StatementArguments(args))
            let entries = rows.map { row in
                LogEntry(
                    id: row["id"],
                    ts: row["ts"],
                    level: row["level"],
                    module: row["module"],
                    message: row["message"],
                    traceId: row["trace_id"],
                    source: row["source"],
                    errorName: row["error_name"],
                    errorMessage: row["error_message"]
                )
            }
            return LogQueryResult(entries: entries, modules: modules)
        }

        return observation
            .removeDuplicates()
            .start(in: pool, scheduling: .immediate, onError: onError, onChange: onChange)
    }

    func observabilityTableCounts() throws -> [(table: String, count: Int)] {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            let tables = ["sessions", "logs", "traces", "metrics", "metrics_hourly", "sessions_fts"]
            var results: [(table: String, count: Int)] = []
            for table in tables {
                // Use IF EXISTS pattern — table may not exist yet
                let exists = try Row.fetchOne(db, sql: """
                    SELECT name FROM sqlite_master WHERE type='table' AND name=?
                """, arguments: [table])
                if exists != nil {
                    // Safe: table names come from the hardcoded `tables` array above, not user input.
                    // SQLite does not support parameterized table names, so string interpolation is required here.
                    let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? 0
                    results.append((table: table, count: count))
                }
            }
            return results
        }
    }
}
