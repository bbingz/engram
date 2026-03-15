// macos/Engram/Core/Database.swift
import Foundation
import GRDB

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

@MainActor
class DatabaseManager: ObservableObject {
    nonisolated(unsafe) private let dbPath: String
    nonisolated(unsafe) private var pool: DatabasePool?
    private var writerPool: DatabasePool?

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
                if subAgent { parts.append("AND agent_role IS NOT NULL") }
                else        { parts.append("AND agent_role IS NULL") }
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
                if subAgent { parts.append("AND agent_role IS NOT NULL") }
                else        { parts.append("AND agent_role IS NULL") }
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
                if subAgent { parts.append("AND agent_role IS NOT NULL") }
                else        { parts.append("AND agent_role IS NULL") }
            }
            return try Int.fetchOne(db, sql: parts.joined(separator: " "),
                                    arguments: StatementArguments(args)) ?? 0
        }
    }

    // MARK: - search (FTS5 trigram)
    func search(query: String, limit: Int = 10) throws -> [Session] {
        guard let pool else { throw DatabaseError.notOpen }
        guard query.count >= 3 else { return [] }
        return try pool.read { db in
            let matches = try FtsMatch.fetchAll(db,
                sql: "SELECT session_id, content FROM sessions_fts WHERE sessions_fts MATCH ? ORDER BY rank LIMIT ?",
                arguments: [query, limit * 3])
            var seen = Set<String>()
            var results: [Session] = []
            for match in matches {
                guard !seen.contains(match.sessionId) else { continue }
                seen.insert(match.sessionId)
                if let s = try Session.fetchOne(db,
                    sql: "SELECT * FROM sessions WHERE id = ? AND hidden_at IS NULL",
                    arguments: [match.sessionId]) {
                    results.append(s)
                    if results.count >= limit { break }
                }
            }
            return results
        }
    }

    // MARK: - project_timeline
    func projectTimeline(project: String? = nil) throws -> [TimelineEntry] {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            var sql = """
                SELECT project, COUNT(*) as session_count, MAX(start_time) as last_updated
                FROM sessions
                WHERE hidden_at IS NULL
                """
            var args: [DatabaseValueConvertible] = []
            if let project {
                sql += " AND project LIKE ?"
                args.append("%\(project)%")
            }
            sql += " GROUP BY project ORDER BY last_updated DESC"
            return try TimelineEntry.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    // MARK: - stats
    struct StatsResult {
        let totalSessions: Int
        let totalMessages: Int
        let bySource: [String: Int]
    }

    func stats() throws -> StatsResult {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
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

    // MARK: - get_context
    func getContext(cwd: String, limit: Int = 5) throws -> [Session] {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            let project = URL(fileURLWithPath: cwd).lastPathComponent
            var results = try Session.fetchAll(db,
                sql: "SELECT * FROM sessions WHERE hidden_at IS NULL AND project LIKE ? AND message_count > 0 ORDER BY start_time DESC LIMIT ?",
                arguments: ["%\(project)%", limit])
            if results.isEmpty && !cwd.isEmpty {
                results = try Session.fetchAll(db,
                    sql: "SELECT * FROM sessions WHERE hidden_at IS NULL AND cwd LIKE ? ORDER BY start_time DESC LIMIT ?",
                    arguments: ["%\(cwd)%", limit])
            }
            return results
        }
    }

    // MARK: - Favorites (writable extension table)
    func addFavorite(sessionId: String) throws {
        guard let writer = writerPool else { throw DatabaseError.notOpen }
        try writer.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO favorites (session_id, created_at)
                VALUES (?, datetime('now'))
            """, arguments: [sessionId])
        }
    }

    func removeFavorite(sessionId: String) throws {
        guard let writer = writerPool else { throw DatabaseError.notOpen }
        try writer.write { db in
            try db.execute(sql: "DELETE FROM favorites WHERE session_id = ?",
                           arguments: [sessionId])
        }
    }

    func listFavorites() throws -> [Session] {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            try Session.fetchAll(db, sql: """
                SELECT s.* FROM sessions s
                JOIN favorites f ON f.session_id = s.id
                WHERE s.hidden_at IS NULL
                ORDER BY f.created_at DESC
            """)
        }
    }

    func isFavorite(sessionId: String) throws -> Bool {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            try Favorite.fetchOne(db,
                sql: "SELECT * FROM favorites WHERE session_id = ?",
                arguments: [sessionId]) != nil
        }
    }

    // MARK: - Hide / Unhide / Rename (writable — sessions table)

    func hideSession(id: String) throws {
        guard let writer = writerPool else { throw DatabaseError.notOpen }
        try writer.write { db in
            try db.execute(
                sql: "UPDATE sessions SET hidden_at = datetime('now') WHERE id = ?",
                arguments: [id])
        }
    }

    func unhideSession(id: String) throws {
        guard let writer = writerPool else { throw DatabaseError.notOpen }
        try writer.write { db in
            try db.execute(
                sql: "UPDATE sessions SET hidden_at = NULL WHERE id = ?",
                arguments: [id])
        }
    }

    func renameSession(id: String, name: String?) throws {
        guard let writer = writerPool else { throw DatabaseError.notOpen }
        try writer.write { db in
            try db.execute(
                sql: "UPDATE sessions SET custom_name = ? WHERE id = ?",
                arguments: [name, id])
        }
    }

    /// Hide truly empty sessions (0 messages AND < 1 KB). Returns count hidden.
    func hideEmptySessions() throws -> Int {
        guard let writer = writerPool else { throw DatabaseError.notOpen }
        return try writer.write { db in
            try db.execute(
                sql: "UPDATE sessions SET hidden_at = datetime('now') WHERE message_count = 0 AND size_bytes < 1024 AND hidden_at IS NULL")
            return db.changesCount
        }
    }

    // MARK: - Hidden sessions (trash)

    func listHiddenSessions(limit: Int = 200, offset: Int = 0) throws -> [Session] {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            try Session.fetchAll(db,
                sql: "SELECT * FROM sessions WHERE hidden_at IS NOT NULL ORDER BY hidden_at DESC LIMIT ? OFFSET ?",
                arguments: [limit, offset])
        }
    }

    func countHiddenSessions() throws -> Int {
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE hidden_at IS NOT NULL") ?? 0
        }
    }

    // MARK: - Update session summary
    func updateSessionSummary(id: String, summary: String) throws {
        guard let writer = writerPool else { throw DatabaseError.notOpen }
        try writer.write { db in
            try db.execute(
                sql: "UPDATE sessions SET summary = ? WHERE id = ?",
                arguments: [summary, id]
            )
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
            if let subAgent {
                if subAgent { parts.append("AND agent_role IS NOT NULL") }
                else        { parts.append("AND agent_role IS NULL") }
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
        guard let pool else { throw DatabaseError.notOpen }
        return try pool.read { db in
            let groupColumn = mode == .project ? "project" : "source"

            // Pick aggregate expression + order matching the sort
            let (aggExpr, orderDir): (String, String) = switch sort {
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
                if subAgent { parts.append("AND agent_role IS NOT NULL") }
                else        { parts.append("AND agent_role IS NULL") }
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
                if subAgent { parts.append("AND agent_role IS NOT NULL") }
                else        { parts.append("AND agent_role IS NULL") }
            }

            parts.append("ORDER BY \(sort.rawValue) LIMIT ?")
            args.append(limit)

            return try Session.fetchAll(db, sql: parts.joined(separator: " "),
                                        arguments: StatementArguments(args))
        }
    }
}
