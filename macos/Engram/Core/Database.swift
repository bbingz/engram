// macos/Engram/Core/Database.swift
import Foundation
import GRDB
import Observation

enum DatabaseError: Error {
    case notOpen
}

enum SessionSort: String, Sendable {
    case accessedDesc = "COALESCE(last_accessed_at, start_time) DESC, start_time DESC"
    case accessedAsc  = "COALESCE(last_accessed_at, start_time) ASC, start_time ASC"
    case createdDesc = "start_time DESC"
    case createdAsc  = "start_time ASC"
    case updatedDesc = "COALESCE(end_time, start_time) DESC"
    case updatedAsc  = "COALESCE(end_time, start_time) ASC"

    var usesActivityTime: Bool {
        switch self {
        case .accessedDesc, .accessedAsc, .updatedDesc, .updatedAsc:
            true
        case .createdDesc, .createdAsc:
            false
        }
    }

    var isDescending: Bool {
        switch self {
        case .accessedDesc, .createdDesc, .updatedDesc:
            true
        case .accessedAsc, .createdAsc, .updatedAsc:
            false
        }
    }

    var timelineTimestampSQL: String {
        switch self {
        case .accessedDesc, .accessedAsc:
            "COALESCE(last_accessed_at, end_time, start_time)"
        case .updatedDesc, .updatedAsc:
            "COALESCE(end_time, start_time)"
        case .createdDesc, .createdAsc:
            "start_time"
        }
    }

    func orderSQL(hasAccessMetadata: Bool) -> String {
        if hasAccessMetadata { return rawValue }
        switch self {
        case .accessedDesc:
            return Self.createdDesc.rawValue
        case .accessedAsc:
            return Self.createdAsc.rawValue
        default:
            return rawValue
        }
    }
}

enum GroupingMode: String, CaseIterable {
    case project = "Project"
    case source = "Source"
}

struct SessionListStats {
    let totalSessions: Int
    let totalMessages: Int
    let avgDurationSeconds: Double?
    let sources: [String]
}

@Observable
final class DatabaseManager: @unchecked Sendable {
    @ObservationIgnored private let dbPath: String
    @ObservationIgnored private var pool: DatabasePool?
    @ObservationIgnored private let poolLock = NSLock()
    @ObservationIgnored private static let sessionTimelineMaxLimit = 10_000
    @ObservationIgnored private static let timelineDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// File path to the SQLite database (for background FileManager access)
    var path: String { dbPath }

    // Thread-safe read accessor — GRDB DatabasePool.read is internally thread-safe.
    func readInBackground<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        let pool = try currentPool()
        return try pool.read(block)
    }

    init(path: String? = nil) {
        self.dbPath = path ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".engram/index.sqlite").path
    }

    func open() throws {
        poolLock.lock()
        defer { poolLock.unlock() }
        guard pool == nil else { return }
        pool = try Self.openReadOnlyPool(at: dbPath)
    }

    private func currentPool() throws -> DatabasePool {
        // Always read `pool` under the lock; a lock-free fast-path read would
        // race with the write below.
        poolLock.lock()
        defer { poolLock.unlock() }
        if let pool {
            return pool
        }
        let opened = try Self.openReadOnlyPool(at: dbPath)
        pool = opened
        return opened
    }

    private static func openReadOnlyPool(at path: String) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.readonly = true
        // Match SQLiteConnectionPolicy.cacheSizeKiB (16 MiB page cache) so the GUI
        // read path — including searchWithSnippets over the hundreds-of-MB FTS
        // index — keeps hot FTS pages resident across queries instead of the
        // ~2 MiB default. (mmap is intentionally NOT enabled; see
        // SQLiteConnectionPolicy for the VACUUM/SIGBUS rationale.)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA cache_size = -\(SharedDBConfig.cacheSizeKiB)")
        }
        return try DatabasePool(path: path, configuration: configuration)
    }

    // MARK: - list_sessions
    private static func appendSessionFilters(
        to parts: inout [String],
        args: inout [DatabaseValueConvertible],
        sources: Set<String>,
        projects: Set<String>,
        since: String?,
        includeHidden: Bool,
        subAgent: Bool?,
        topLevelOnly: Bool,
        humanDriven: Bool
    ) {
        if !includeHidden {
            parts.append("AND hidden_at IS NULL")
        }
        if topLevelOnly {
            parts.append("AND parent_session_id IS NULL AND suggested_parent_id IS NULL")
        }
        if humanDriven {
            parts.append("AND (\(HumanDrivenFilter.sqlPredicate))")
        }
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
        if let since {
            parts.append("AND COALESCE(end_time, start_time) >= ?")
            args.append(since)
        }
        if let subAgent {
            if subAgent {
                parts.append("AND (agent_role IS NOT NULL OR file_path LIKE '%/subagents/%')")
            } else {
                parts.append("AND (tier IS NULL OR tier != 'skip')")
            }
        }
    }

    private static func hasSessionAccessMetadata(in db: GRDB.Database) throws -> Bool {
        let names = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('sessions')")
        return names.contains("last_accessed_at") && names.contains("access_count")
    }

    func listSessions(
        sources: Set<String> = [],   // empty = all
        projects: Set<String> = [],  // empty = all
        since: String? = nil,
        includeHidden: Bool = false,
        subAgent: Bool? = nil,       // nil=all, true=only sub-agents, false=hide sub-agents
        topLevelOnly: Bool = false,
        humanDriven: Bool = false,
        sort: SessionSort = .accessedDesc,
        limit: Int = 200,
        offset: Int = 0
    ) throws -> [Session] {
        try readInBackground { db in
            var parts = ["SELECT * FROM sessions WHERE 1=1"]
            var args: [DatabaseValueConvertible] = []
            Self.appendSessionFilters(
                to: &parts,
                args: &args,
                sources: sources,
                projects: projects,
                since: since,
                includeHidden: includeHidden,
                subAgent: subAgent,
                topLevelOnly: topLevelOnly,
                humanDriven: humanDriven
            )
            let orderSQL = sort.orderSQL(hasAccessMetadata: try Self.hasSessionAccessMetadata(in: db))
            parts.append("ORDER BY \(orderSQL) LIMIT ? OFFSET ?")
            args.append(limit); args.append(offset)
            return try Session.fetchAll(db, sql: parts.joined(separator: " "),
                                        arguments: StatementArguments(args))
        }
    }

    func sessionListStats(
        sources: Set<String> = [],
        projects: Set<String> = [],
        since: String? = nil,
        includeHidden: Bool = false,
        subAgent: Bool? = nil,
        topLevelOnly: Bool = false,
        humanDriven: Bool = false
    ) throws -> SessionListStats {
        try readInBackground { db in
            var parts = ["FROM sessions WHERE 1=1"]
            var args: [DatabaseValueConvertible] = []
            Self.appendSessionFilters(
                to: &parts,
                args: &args,
                sources: sources,
                projects: projects,
                since: since,
                includeHidden: includeHidden,
                subAgent: subAgent,
                topLevelOnly: topLevelOnly,
                humanDriven: humanDriven
            )
            let fromWhere = parts.joined(separator: " ")
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    COUNT(*) AS total_sessions,
                    COALESCE(SUM(message_count), 0) AS total_messages,
                    AVG(CASE
                        WHEN end_time IS NOT NULL
                        THEN (julianday(end_time) - julianday(start_time)) * 86400.0
                    END) AS avg_duration_seconds
                \(fromWhere)
            """, arguments: StatementArguments(args))
            let sourceRows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT source
                \(fromWhere)
                ORDER BY source
            """, arguments: StatementArguments(args))
            return SessionListStats(
                totalSessions: row?["total_sessions"] ?? 0,
                totalMessages: row?["total_messages"] ?? 0,
                avgDurationSeconds: row?["avg_duration_seconds"],
                sources: sourceRows.map { $0["source"] as String }
            )
        }
    }

    // MARK: - list projects
    func listProjects() throws -> [String] {
        try readInBackground { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT project FROM sessions
                WHERE project IS NOT NULL AND hidden_at IS NULL
                ORDER BY project
            """)
        }
    }

    func countsBySource() throws -> [String: Int] {
        try readInBackground { db in
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

    func sourceStats() throws -> [SourceStat] {
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
        try readInBackground { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT project, COUNT(*) as n FROM sessions
                WHERE project IS NOT NULL AND hidden_at IS NULL GROUP BY project
            """)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["project"] as String, $0["n"] as Int) })
        }
    }

    func listSessionsForProject(_ project: String?, subAgent: Bool? = nil, limit: Int = 100) throws -> [Session] {
        try readInBackground { db in
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
                if subAgent { parts.append("AND (agent_role IS NOT NULL OR file_path LIKE '%/subagents/%')") }
                else        { parts.append("AND (tier IS NULL OR tier != 'skip')") }
            }
            parts.append("ORDER BY start_time DESC LIMIT ?")
            args.append(limit)
            return try Session.fetchAll(db, sql: parts.joined(separator: " "),
                                        arguments: StatementArguments(args))
        }
    }

    func getSession(id: String) throws -> Session? {
        try readInBackground { db in
            try Session.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [id])
        }
    }

    func countSessions(
        sources: Set<String> = [],
        projects: Set<String> = [],
        subAgent: Bool? = nil
    ) throws -> Int {
        try readInBackground { db in
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
                if subAgent { parts.append("AND (agent_role IS NOT NULL OR file_path LIKE '%/subagents/%')") }
                else        { parts.append("AND (tier IS NULL OR tier != 'skip')") }
            }
            return try Int.fetchOne(db, sql: parts.joined(separator: " "),
                                    arguments: StatementArguments(args)) ?? 0
        }
    }

    // MARK: - search (FTS5 trigram)

    private static func tableExists(_ table: String, db: GRDB.Database) throws -> Bool {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [table]
        ) ?? 0
        return count > 0
    }

    private static func appendSearchFilters(
        to parts: inout [String],
        args: inout [DatabaseValueConvertible],
        sources: Set<String>,
        projects: Set<String>,
        since: String?
    ) {
        if !sources.isEmpty {
            let ph = sources.map { _ in "?" }.joined(separator: ", ")
            parts.append("AND s.source IN (\(ph))")
            sources.forEach { args.append($0) }
        }
        if !projects.isEmpty {
            let ph = projects.map { _ in "?" }.joined(separator: ", ")
            parts.append("AND s.project IN (\(ph))")
            projects.forEach { args.append($0) }
        }
        if let since {
            parts.append("AND COALESCE(s.end_time, s.start_time) >= ?")
            args.append(since)
        }
    }

    func search(
        query: String,
        limit: Int = 10,
        sources: Set<String> = [],
        projects: Set<String> = [],
        since: String? = nil
    ) throws -> [Session] {
        guard query.count >= 2 else { return [] }

        // CJK uses LIKE because trigram MATCH is unreliable for CJK/Hangul.
        // Two-character Latin abbreviations ("AI", "PR", "UI") also need LIKE
        // because the trigram tokenizer cannot MATCH terms shorter than three
        // characters. Escape wildcards so literal "%"/"_" match verbatim.
        if CJKText.containsCJK(query) || query.count < 3 {
            let pattern = "%\(CJKText.escapeLikePattern(query))%"
            return try readInBackground { db in
                var parts = ["""
                    SELECT DISTINCT s.* FROM sessions_fts f
                    JOIN sessions s ON s.id = f.session_id
                    WHERE f.content LIKE ? ESCAPE '\\' AND s.hidden_at IS NULL
                      AND (s.tier IS NULL OR s.tier NOT IN ('skip', 'lite'))
                """]
                var args: [DatabaseValueConvertible] = [pattern]
                Self.appendSearchFilters(
                    to: &parts,
                    args: &args,
                    sources: sources,
                    projects: projects,
                    since: since
                )
                parts.append("""
                    ORDER BY s.start_time DESC
                    LIMIT ?
                """)
                args.append(limit)
                return try Session.fetchAll(db, sql: """
                    \(parts.joined(separator: " "))
                """, arguments: StatementArguments(args))
            }
        }

        // ASCII/Latin: use fast FTS MATCH
        guard query.count >= 3 else { return [] }
        return try readInBackground { db in
            let termMatches = CJKText.ftsMatchTerms(query)
            let snippetMatch = termMatches.first ?? CJKText.ftsMatchQuery(query)
            var parts = ["""
                SELECT s.*
                FROM sessions s
                WHERE s.hidden_at IS NULL
                  AND (s.tier IS NULL OR s.tier NOT IN ('skip', 'lite'))
            """]
            var args: [DatabaseValueConvertible] = []
            for termMatch in termMatches {
                parts.append("""
                    AND EXISTS (
                        SELECT 1 FROM sessions_fts
                        WHERE sessions_fts MATCH ? AND session_id = s.id
                    )
                """)
                args.append(termMatch)
            }
            Self.appendSearchFilters(
                to: &parts,
                args: &args,
                sources: sources,
                projects: projects,
                since: since
            )
            parts.append("""
                ORDER BY (
                    SELECT MIN(rank) FROM sessions_fts
                    WHERE sessions_fts MATCH ? AND session_id = s.id
                ), s.start_time DESC
                LIMIT ?
            """)
            args.append(snippetMatch)
            args.append(limit)
            return try Session.fetchAll(
                db,
                sql: parts.joined(separator: " "),
                arguments: StatementArguments(args)
            )
        }
    }

    /// Like `search`, but returns each session paired with a match-centered,
    /// `<mark>`-highlighted snippet. Used by the GUI offline-fallback path so a
    /// service outage still shows the same windowed highlights as the live
    /// (service) path, instead of an empty snippet.
    func searchWithSnippets(
        query: String,
        limit: Int = 10,
        sources: Set<String> = [],
        projects: Set<String> = [],
        since: String? = nil
    ) throws -> [(session: Session, snippet: String)] {
        guard query.count >= 2 else { return [] }

        if CJKText.containsCJK(query) || query.count < 3 {
            let pattern = "%\(CJKText.escapeLikePattern(query))%"
            return try readInBackground { db in
                var parts = ["""
                    SELECT s.*, f.content AS snippet FROM sessions_fts f
                    JOIN sessions s ON s.id = f.session_id
                    WHERE f.content LIKE ? ESCAPE '\\' AND s.hidden_at IS NULL
                      AND (s.tier IS NULL OR s.tier NOT IN ('skip', 'lite'))
                """]
                var args: [DatabaseValueConvertible] = [pattern]
                Self.appendSearchFilters(to: &parts, args: &args, sources: sources, projects: projects, since: since)
                parts.append("GROUP BY s.id ORDER BY s.start_time DESC LIMIT ?")
                args.append(limit)
                let rows = try Row.fetchAll(db, sql: parts.joined(separator: " "), arguments: StatementArguments(args))
                return try rows.map { row in
                    let content = (row["snippet"] as String?) ?? ""
                    let snippet = CJKText.cjkHighlightedSnippet(content: content, query: query) ?? content
                    return (try Session(row: row), snippet)
                }
            }
        }

        guard query.count >= 3 else { return [] }
        return try readInBackground { db in
            let termMatches = CJKText.ftsMatchTerms(query)
            let snippetMatch = termMatches.first ?? CJKText.ftsMatchQuery(query)
            var parts = ["""
                SELECT s.*, (
                    SELECT snippet(sessions_fts, 1, '<mark>', '</mark>', '…', 32)
                    FROM sessions_fts
                    WHERE sessions_fts MATCH ? AND session_id = s.id
                    ORDER BY rank
                    LIMIT 1
                ) AS snippet
                FROM sessions s
                WHERE s.hidden_at IS NULL
                  AND (s.tier IS NULL OR s.tier NOT IN ('skip', 'lite'))
            """]
            // Search at session granularity: every query token must exist
            // somewhere in the session, not necessarily in the same FTS row.
            var args: [DatabaseValueConvertible] = [snippetMatch]
            for termMatch in termMatches {
                parts.append("""
                    AND EXISTS (
                        SELECT 1 FROM sessions_fts
                        WHERE sessions_fts MATCH ? AND session_id = s.id
                    )
                """)
                args.append(termMatch)
            }
            Self.appendSearchFilters(to: &parts, args: &args, sources: sources, projects: projects, since: since)
            parts.append("""
                ORDER BY (
                    SELECT MIN(rank) FROM sessions_fts
                    WHERE sessions_fts MATCH ? AND session_id = s.id
                ), s.start_time DESC
                LIMIT ?
            """)
            args.append(snippetMatch)
            args.append(limit)
            let rows = try Row.fetchAll(db, sql: parts.joined(separator: " "), arguments: StatementArguments(args))
            return try rows.map { row in
                (try Session(row: row), (row["snippet"] as String?) ?? "")
            }
        }
    }

    // MARK: - project_timeline
    func projectTimeline(project: String? = nil) throws -> [TimelineEntry] {
        try readInBackground { db in
            var sql = """
                SELECT project, COUNT(*) as session_count, MAX(start_time) as last_updated
                FROM sessions
                WHERE hidden_at IS NULL
                """
            var args: [DatabaseValueConvertible] = []
            if let project {
                sql += " AND project LIKE ? ESCAPE '\\'"
                args.append("%\(CJKText.escapeLikePattern(project))%")
            }
            sql += " GROUP BY project ORDER BY last_updated DESC"
            return try TimelineEntry.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    func implementationTimeline(
        days: Int = 30,
        project: String? = nil,
        humanDriven: Bool = false
    ) throws -> [ImplementationTimelineItem] {
        try readInBackground { db in
            guard try Self.tableExists("session_work_beats", db: db) else { return [] }
            // work_item_titles is service/writer-owned, so the read-only app pool
            // must guard it and fall back to heuristic titles when the table is absent.
            let hasTitles = try Self.tableExists("work_item_titles", db: db)
            let titleColumn = hasTitles ? ", wt.title AS semantic_title" : ""
            let titleJoin = hasTitles
                ? "LEFT JOIN work_item_titles wt ON wt.project = s.project AND wt.work_key = b.work_key"
                : ""
            var parts = ["""
                SELECT b.session_id, b.beat_index, b.action_date, b.action_timestamp,
                       b.work_key, b.work_title, b.human_intent, b.assistant_outcome,
                       b.kind, b.status, b.operation_events, b.confidence\(titleColumn)
                FROM session_work_beats b
                JOIN sessions s ON s.id = b.session_id
                \(titleJoin)
                WHERE s.hidden_at IS NULL
                  AND s.parent_session_id IS NULL
                  AND s.suggested_parent_id IS NULL
                  AND (s.tier IS NULL OR s.tier != 'skip')
            """]
            var args: [DatabaseValueConvertible] = []
            if days < 100_000,
               let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: Date()) {
                parts.append("AND b.action_date >= ?")
                args.append(Self.timelineDateFormatter.string(from: cutoff))
            }
            if let project, !project.isEmpty {
                parts.append("AND s.project = ?")
                args.append(project)
            }
            if humanDriven {
                parts.append("AND \(HumanDrivenFilter.sqlPredicate(alias: "s"))")
            }
            parts.append("ORDER BY b.action_date ASC, b.action_timestamp ASC, b.session_id ASC, b.beat_index ASC")

            let rows = try Row.fetchAll(db, sql: parts.joined(separator: " "), arguments: StatementArguments(args))
            let beats = rows.map(Self.sessionImplementationBeat(row:))
            let items = ImplementationTimelineBuilder.build(beats: beats)
            // Semantic titles are scoped by (project, work_key); the cross-project
            // global timeline keeps heuristic titles.
            guard hasTitles, project != nil else { return items }
            var titleByWorkKey: [String: String] = [:]
            for row in rows {
                if let title = row["semantic_title"] as String?, !title.isEmpty {
                    titleByWorkKey[row["work_key"] as String] = title
                }
            }
            guard !titleByWorkKey.isEmpty else { return items }
            return items.map { item in
                var copy = item
                copy.semanticTitle = titleByWorkKey[item.workKey]
                return copy
            }
        }
    }

    private static func sessionImplementationBeat(row: Row) -> SessionImplementationBeat {
        let eventsJSON: String = row["operation_events"] ?? "[]"
        return SessionImplementationBeat(
            sessionId: row["session_id"],
            beatIndex: row["beat_index"],
            actionDate: row["action_date"],
            actionTimestamp: row["action_timestamp"],
            workKey: row["work_key"],
            workTitle: row["work_title"],
            humanIntent: row["human_intent"],
            assistantOutcome: row["assistant_outcome"],
            kind: SessionImplementationKind(rawValue: row["kind"]) ?? .implementation,
            status: SessionImplementationStatus(rawValue: row["status"]) ?? .partial,
            operationEvents: decodeOperationEvents(eventsJSON),
            confidence: row["confidence"]
        )
    }

    private static func decodeOperationEvents(_ json: String) -> [SessionOperationEvent] {
        guard let data = json.data(using: .utf8),
              let events = try? JSONDecoder().decode([SessionOperationEvent].self, from: data)
        else { return [] }
        return events
    }

    // MARK: - stats
    struct StatsResult {
        let totalSessions: Int
        let totalMessages: Int
        let bySource: [String: Int]
    }

    func stats() throws -> StatsResult {
        try readInBackground { db in
            let total    = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE hidden_at IS NULL") ?? 0
            let messages = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(message_count), 0) FROM sessions WHERE hidden_at IS NULL") ?? 0
            let counts   = try SourceCount.fetchAll(db,
                sql: "SELECT source, COUNT(*) as count FROM sessions WHERE hidden_at IS NULL GROUP BY source ORDER BY count DESC")
            return StatsResult(totalSessions: total, totalMessages: messages,
                               bySource: Dictionary(uniqueKeysWithValues: counts.map { ($0.source, $0.count) }))
        }
    }

    func dbSizeBytes() -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: dbPath)[.size] as? Int64) ?? 0
    }

    /// UI-M4: real journal mode via PRAGMA instead of a hardcoded "WAL Mode: OK".
    func journalMode() throws -> String {
        try readInBackground { db in
            (try String.fetchOne(db, sql: "PRAGMA journal_mode")) ?? "unknown"
        }
    }

    func cacheSize() throws -> Int {
        try readInBackground { db in
            (try Int.fetchOne(db, sql: "PRAGMA cache_size")) ?? 0
        }
    }

    // MARK: - get_context
    func getContext(cwd: String, limit: Int = 5) throws -> [Session] {
        try readInBackground { db in
            let project = URL(fileURLWithPath: cwd).lastPathComponent
            var results = try Session.fetchAll(db,
                sql: "SELECT * FROM sessions WHERE hidden_at IS NULL AND project LIKE ? ESCAPE '\\' AND message_count > 0 ORDER BY start_time DESC LIMIT ?",
                arguments: ["%\(CJKText.escapeLikePattern(project))%", limit])
            if results.isEmpty && !cwd.isEmpty {
                results = try Session.fetchAll(db,
                    sql: "SELECT * FROM sessions WHERE hidden_at IS NULL AND cwd LIKE ? ESCAPE '\\' ORDER BY start_time DESC LIMIT ?",
                    arguments: ["%\(CJKText.escapeLikePattern(cwd))%", limit])
            }
            return results
        }
    }

    // MARK: - file activity (Top Files; service-owned extension table)
    // Mirrors MCPDatabase.getFileActivity SQL for the app read path. Guarded by
    // tableExists so older DBs without session_files return [] instead of throwing.
    func fileActivity(project: String?, since: String?, limit: Int)
        throws -> [(filePath: String, action: String, totalCount: Int, sessionCount: Int)] {
        try readInBackground { db in
            guard try Self.tableExists("session_files", db: db) else { return [] }
            var conditions: [String] = []
            var args: [DatabaseValueConvertible] = []
            if let project {
                conditions.append("s.project = ?")
                args.append(project)
            }
            if let since {
                conditions.append("s.start_time >= ?")
                args.append(since)
            }
            let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
            args.append(limit)
            let rows = try Row.fetchAll(db, sql: """
                SELECT sf.file_path, sf.action,
                       SUM(sf.count) AS total_count,
                       COUNT(DISTINCT sf.session_id) AS session_count
                FROM session_files sf
                JOIN sessions s ON s.id = sf.session_id
                \(whereClause)
                GROUP BY sf.file_path, sf.action
                ORDER BY total_count DESC
                LIMIT ?
            """, arguments: StatementArguments(args))
            return rows.map {
                (filePath: ($0["file_path"] as String?) ?? "",
                 action: ($0["action"] as String?) ?? "",
                 totalCount: ($0["total_count"] as Int?) ?? 0,
                 sessionCount: ($0["session_count"] as Int?) ?? 0)
            }
        }
    }

    // Related sessions for a repo via an anchored cwd-prefix match (cwd LIKE path%),
    // replacing getContext's unanchored project-substring/cwd-substring over-match.
    func sessionsForRepo(path: String, limit: Int = 10) throws -> [Session] {
        // Anchor at a path boundary so "/Users/a/app" matches the repo and its
        // subdirectories but NOT a sibling like "/Users/a/app-v2". Escape LIKE
        // metacharacters (\ % _) in the prefix — "_" is common in directory names.
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try readInBackground { db in
            try Session.fetchAll(db,
                sql: "SELECT * FROM sessions WHERE hidden_at IS NULL AND (cwd = ? OR cwd LIKE ? ESCAPE '\\') ORDER BY start_time DESC LIMIT ?",
                arguments: [path, "\(escaped)/%", limit])
        }
    }

    // MARK: - Favorites (service-owned extension table)
    func listFavorites() throws -> [Session] {
        try readInBackground { db in
            guard try Self.tableExists("favorites", db: db) else { return [] }
            return try Session.fetchAll(db, sql: """
                SELECT s.* FROM sessions s
                JOIN favorites f ON f.session_id = s.id
                WHERE s.hidden_at IS NULL
                ORDER BY f.created_at DESC
            """)
        }
    }

    func isFavorite(sessionId: String) throws -> Bool {
        try readInBackground { db in
            guard try Self.tableExists("favorites", db: db) else { return false }
            return try Favorite.fetchOne(db,
                sql: "SELECT * FROM favorites WHERE session_id = ?",
                arguments: [sessionId]) != nil
        }
    }

    // MARK: - Hidden sessions (trash)

    func listHiddenSessions(limit: Int = 200, offset: Int = 0) throws -> [Session] {
        try readInBackground { db in
            try Session.fetchAll(db,
                sql: "SELECT * FROM sessions WHERE hidden_at IS NOT NULL ORDER BY hidden_at DESC LIMIT ? OFFSET ?",
                arguments: [limit, offset])
        }
    }

    func countHiddenSessions() throws -> Int {
        try readInBackground { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE hidden_at IS NOT NULL") ?? 0
        }
    }

    // MARK: - Timeline (chronological list)

    /// Pure chronological list of sessions for Timeline view
    func listSessionsChronologically(
        sources: Set<String> = [],
        projects: Set<String> = [],
        subAgent: Bool? = nil,
        limit: Int = 50,
        offset: Int = 0
    ) throws -> [Session] {
        try readInBackground { db in
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
            if let subAgent {
                if subAgent { parts.append("AND (agent_role IS NOT NULL OR file_path LIKE '%/subagents/%')") }
                else        { parts.append("AND (tier IS NULL OR tier != 'skip')") }
            }
            parts.append("ORDER BY start_time DESC LIMIT ? OFFSET ?")
            args.append(limit); args.append(offset)
            return try Session.fetchAll(db, sql: parts.joined(separator: " "),
                                        arguments: StatementArguments(args))
        }
    }

    // MARK: - Grouped Sessions view

    /// Get all group keys with counts for grouped view (by project or source)
    func listGroups(
        by mode: GroupingMode,
        sources: Set<String> = [],
        projects: Set<String> = [],
        subAgent: Bool? = nil,
        sort: SessionSort = .createdDesc
    ) throws -> [(key: String, count: Int, lastUpdated: String)] {
        try readInBackground { db in
            let groupColumn = mode == .project ? "project" : "source"
            let hasAccessMetadata = try Self.hasSessionAccessMetadata(in: db)

            // Pick aggregate expression + order matching the sort
            let (aggExpr, orderDir): (String, String) = switch sort {
            case .accessedDesc:
                (hasAccessMetadata ? "MAX(COALESCE(last_accessed_at, start_time))" : "MAX(start_time)", "DESC")
            case .accessedAsc:
                (hasAccessMetadata ? "MIN(COALESCE(last_accessed_at, start_time))" : "MIN(start_time)", "ASC")
            case .createdDesc: ("MAX(start_time)", "DESC")
            case .createdAsc:  ("MIN(start_time)", "ASC")
            case .updatedDesc: ("MAX(COALESCE(end_time, start_time))", "DESC")
            case .updatedAsc:  ("MIN(COALESCE(end_time, start_time))", "ASC")
            }

            var parts = ["""
                SELECT COALESCE(\(groupColumn), '(unknown)') as group_key,
                       COUNT(*) as count,
                       \(aggExpr) as sort_value
                FROM sessions
                WHERE hidden_at IS NULL
                """]
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
                if subAgent { parts.append("AND (agent_role IS NOT NULL OR file_path LIKE '%/subagents/%')") }
                else        { parts.append("AND (tier IS NULL OR tier != 'skip')") }
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
        try readInBackground { db in
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
                if subAgent { parts.append("AND (agent_role IS NOT NULL OR file_path LIKE '%/subagents/%')") }
                else        { parts.append("AND (tier IS NULL OR tier != 'skip')") }
            }

            parts.append("ORDER BY \(sort.rawValue) LIMIT ?")
            args.append(limit)

            return try Session.fetchAll(db, sql: parts.joined(separator: " "),
                                        arguments: StatementArguments(args))
        }
    }

    /// Sessions symmetrically "related" to `sessionId` (untyped navigational
    /// links, distinct from parent/child). The `id IN (...)` join against
    /// `sessions` filters out dangling relation rows at read time — no cascade
    /// is needed when a peer session disappears. Returns [] if the optional
    /// `session_relations` table was never created.
    func relatedSessions(sessionId: String) throws -> [Session] {
        try readInBackground { db in
            let hasTable = try Bool.fetchOne(
                db,
                sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='session_relations'"
            ) ?? false
            guard hasTable else { return [] }
            return try Session.fetchAll(db, sql: """
                SELECT * FROM sessions
                WHERE hidden_at IS NULL
                  AND id IN (
                    SELECT b_id FROM session_relations WHERE a_id = ?
                    UNION
                    SELECT a_id FROM session_relations WHERE b_id = ?
                  )
                ORDER BY start_time DESC
            """, arguments: [sessionId, sessionId])
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
        try readInBackground { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) as n FROM sessions
                WHERE hidden_at IS NULL AND start_time >= ?
            """, arguments: [since]) else {
                return 0
            }
            return row["n"] as Int
        }
    }

    func kpiStats() throws -> KPIStats {
        try readInBackground { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT
                    COUNT(*) as sessions,
                    COUNT(DISTINCT source) as sources,
                    SUM(message_count) as messages,
                    COUNT(DISTINCT project) as projects
                FROM sessions WHERE hidden_at IS NULL
            """) else {
                return KPIStats(sessions: 0, sources: 0, messages: 0, projects: 0)
            }
            return KPIStats(
                sessions: row["sessions"],
                sources: row["sources"],
                messages: row["messages"] ?? 0,
                projects: row["projects"]
            )
        }
    }

    func dailyActivity(days: Int = 30) throws -> [(date: String, count: Int)] {
        try readInBackground { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT date(start_time, 'localtime') as day, COUNT(*) as count
                FROM sessions
                WHERE hidden_at IS NULL
                  AND date(start_time, 'localtime') >= date('now', 'localtime', '-\(days) days')
                GROUP BY day ORDER BY day
            """)
            return rows.map { (date: $0["day"] as String, count: $0["count"] as Int) }
        }
    }

    func dailySourceActivity(days: Int = 30) throws -> [(date: String, segments: [(source: String, count: Int)])] {
        try readInBackground { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT date(start_time, 'localtime') as day, source, COUNT(*) as count
                FROM sessions
                WHERE hidden_at IS NULL
                  AND date(start_time, 'localtime') >= date('now', 'localtime', '-\(days) days')
                GROUP BY day, source
                ORDER BY day
            """)

            var result: [(date: String, segments: [(source: String, count: Int)])] = []
            var currentDay: String?
            var currentSegments: [(source: String, count: Int)] = []

            for row in rows {
                let day = row["day"] as String
                if let currentDay, currentDay != day {
                    result.append((date: currentDay, segments: currentSegments))
                    currentSegments = []
                }
                currentDay = day
                currentSegments.append((source: row["source"] as String, count: row["count"] as Int))
            }

            if let currentDay {
                result.append((date: currentDay, segments: currentSegments))
            }

            return result
        }
    }

    func hourlyActivity() throws -> [Int] {
        try readInBackground { db in
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
        try readInBackground { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT source, COUNT(*) as count
                FROM sessions WHERE hidden_at IS NULL
                GROUP BY source ORDER BY count DESC
            """)
            return rows.map { (source: $0["source"] as String, count: $0["count"] as Int) }
        }
    }

    func tierDistribution() throws -> (premium: Int, normal: Int, lite: Int, skip: Int) {
        try readInBackground { db in
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

    func recentSessions(limit: Int = 8, humanDriven: Bool = false) throws -> [Session] {
        let humanClause = humanDriven ? "AND (\(HumanDrivenFilter.sqlPredicate))" : ""
        return try readInBackground { db in
            try Session.fetchAll(db, sql: """
                SELECT * FROM sessions
                WHERE hidden_at IS NULL
                  AND parent_session_id IS NULL
                  AND suggested_parent_id IS NULL
                  AND (tier IS NULL OR tier != 'skip')
                  \(humanClause)
                ORDER BY start_time DESC LIMIT ?
            """, arguments: [limit])
        }
    }

    func sessionTimeline(
        days: Int = 30,
        sort: SessionSort = .updatedDesc,
        humanDriven: Bool = false,
        limit: Int = 2_000
    ) throws -> [(date: String, sessions: [Session])] {
        let humanClause = humanDriven ? "AND (\(HumanDrivenFilter.sqlPredicate))" : ""
        let boundedLimit = min(max(limit, 1), Self.sessionTimelineMaxLimit)
        return try readInBackground { db in
            let timestampSQL = sort.timelineTimestampSQL
            let sessions = try Session.fetchAll(db, sql: """
                SELECT * FROM sessions
                WHERE hidden_at IS NULL
                  AND parent_session_id IS NULL
                  AND suggested_parent_id IS NULL
                  AND \(timestampSQL) >= DATE('now', '-\(days) days')
                  AND (tier IS NULL OR tier != 'skip')
                  \(humanClause)
                ORDER BY \(sort.rawValue)
                LIMIT ?
            """, arguments: [boundedLimit])
            func timelineTimestamp(_ session: Session) -> String {
                switch sort {
                case .accessedDesc, .accessedAsc:
                    session.lastAccessedAt ?? session.endTime ?? session.startTime
                case .updatedDesc, .updatedAsc:
                    session.endTime ?? session.startTime
                case .createdDesc, .createdAsc:
                    session.startTime
                }
            }

            let grouped = Dictionary(grouping: sessions) {
                EngramTimestampParser.localDateKey(from: timelineTimestamp($0))
            }
            return grouped
                .sorted { sort.isDescending ? $0.key > $1.key : $0.key < $1.key }
                .map { group in
                    let sortedSessions = group.value.sorted {
                        sort.isDescending ? timelineTimestamp($0) > timelineTimestamp($1) : timelineTimestamp($0) < timelineTimestamp($1)
                    }
                    return (date: group.key, sessions: sortedSessions)
                }
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
        try readInBackground { db in
            try GitRepo.fetchAll(db, sql: "SELECT * FROM git_repos ORDER BY last_commit_at DESC")
        }
    }

    /// Returns session counts for the last 7 days (index 0 = 6 days ago, index 6 = today)
    /// for sessions whose cwd starts with repoPath.
    func sparklineData(for repoPath: String) throws -> [Int] {
        try readInBackground { db in
            // Bucket by LOCAL calendar day so it agrees with the Swift side, which
            // compares against the local start-of-day. Without 'localtime' the SQL
            // bucketed by UTC day and the day string was reparsed in local time,
            // causing an off-by-one bucket for sessions near midnight.
            let rows = try Row.fetchAll(db, sql: """
                SELECT date(start_time, 'localtime') as day, COUNT(*) as n
                FROM sessions
                WHERE hidden_at IS NULL
                  AND (tier IS NULL OR tier != 'skip')
                  AND cwd LIKE ? ESCAPE '\\'
                  AND date(start_time, 'localtime') >= date('now', 'localtime', '-6 days')
                GROUP BY day
            """, arguments: ["\(CJKText.escapeLikePattern(repoPath))%"])
            var counts = [Int](repeating: 0, count: 7)
            let today = Calendar.current.startOfDay(for: Date())
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            fmt.timeZone = .current
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
        try readInBackground { db in
            let sessions = try Session.fetchAll(db, sql: """
                SELECT * FROM sessions
                WHERE hidden_at IS NULL AND project IS NOT NULL
                  AND parent_session_id IS NULL
                  AND suggested_parent_id IS NULL
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

    // MARK: - Parent/Child Session Queries

    func childSessions(
        parentId: String,
        includeHidden: Bool = false,
        limit: Int = 20,
        offset: Int = 0
    ) throws -> [Session] {
        try readInBackground { db in
            let hiddenClause = includeHidden ? "" : "AND hidden_at IS NULL"
            return try Session.fetchAll(db, sql: """
                SELECT * FROM sessions
                WHERE parent_session_id = ? \(hiddenClause)
                ORDER BY start_time ASC
                LIMIT ? OFFSET ?
            """, arguments: [parentId, limit, offset])
        }
    }

    func suggestedChildSessions(parentId: String, includeHidden: Bool = false) throws -> [Session] {
        try readInBackground { db in
            let hiddenClause = includeHidden ? "" : "AND hidden_at IS NULL"
            return try Session.fetchAll(db, sql: """
                SELECT * FROM sessions
                WHERE suggested_parent_id = ?
                  AND parent_session_id IS NULL
                  \(hiddenClause)
                ORDER BY start_time ASC
            """, arguments: [parentId])
        }
    }

    /// Flat inbox of sessions awaiting parent-link review: every top-level
    /// session carrying a non-null suggested_parent_id. Unlike
    /// suggestedChildSessions this needs no known parent, so the Agents page can
    /// surface the Layer-2 heuristic across the whole index in one read.
    func pendingSuggestionSessions(includeHidden: Bool = false, limit: Int = 200) throws -> [Session] {
        try readInBackground { db in
            let hiddenClause = includeHidden ? "" : "AND hidden_at IS NULL"
            return try Session.fetchAll(db, sql: """
                SELECT * FROM sessions
                WHERE suggested_parent_id IS NOT NULL
                  AND parent_session_id IS NULL
                  \(hiddenClause)
                ORDER BY start_time DESC
                LIMIT ?
            """, arguments: [limit])
        }
    }

    func childCount(parentIds: [String], includeHidden: Bool = false) throws -> [String: Int] {
        guard !parentIds.isEmpty else { return [:] }
        return try readInBackground { db in
            let placeholders = parentIds.map { _ in "?" }.joined(separator: ",")
            let hiddenClause = includeHidden ? "" : "AND hidden_at IS NULL"
            let rows = try Row.fetchAll(db, sql: """
                SELECT parent_session_id, COUNT(*) as cnt
                FROM sessions
                WHERE parent_session_id IN (\(placeholders)) \(hiddenClause)
                GROUP BY parent_session_id
            """, arguments: StatementArguments(parentIds))
            var result: [String: Int] = [:]
            for row in rows {
                let pid: String = row["parent_session_id"]
                let cnt: Int = row["cnt"]
                result[pid] = cnt
            }
            return result
        }
    }

    func suggestedChildCount(parentIds: [String], includeHidden: Bool = false) throws -> [String: Int] {
        guard !parentIds.isEmpty else { return [:] }
        return try readInBackground { db in
            let placeholders = parentIds.map { _ in "?" }.joined(separator: ",")
            let hiddenClause = includeHidden ? "" : "AND hidden_at IS NULL"
            let rows = try Row.fetchAll(db, sql: """
                SELECT suggested_parent_id, COUNT(*) as cnt
                FROM sessions
                WHERE suggested_parent_id IN (\(placeholders))
                  AND parent_session_id IS NULL \(hiddenClause)
                GROUP BY suggested_parent_id
            """, arguments: StatementArguments(parentIds))
            var result: [String: Int] = [:]
            for row in rows {
                let pid: String = row["suggested_parent_id"]
                let cnt: Int = row["cnt"]
                result[pid] = cnt
            }
            return result
        }
    }

    // MARK: - Observability: Logs

    func fetchLogs(level: String, module: String, limit: Int) throws -> LogQueryResult {
        try readInBackground { db in
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
        try readInBackground { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM logs
                WHERE level = 'error'
                  AND ts >= datetime('now', '-24 hours')
            """) ?? 0
        }
    }

    func errorsByModule24h() throws -> [(module: String, count: Int)] {
        try readInBackground { db in
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
        try readInBackground { db in
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
        try readInBackground { db in
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
        try readInBackground { db in
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
        try readInBackground { db in
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

    func observabilityTableCounts() throws -> [(table: String, count: Int)] {
        try readInBackground { db in
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
