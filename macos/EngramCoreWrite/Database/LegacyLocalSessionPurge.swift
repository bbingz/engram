import Foundation
import GRDB
import EngramCoreRead

/// D7 cleanup of legacy `origin=local` grok/pi rows that an index host stored
/// before its legacy scan was role-gated.
///
/// docs/invariants.md "Legacy Local-Origin Purge Is An Explicit Operator Action":
/// `report` is SELECT-only (safe on a read-only backup copy), and `purge` runs
/// only inside the caller's transaction, only for the exact plan (count plus
/// token) the operator approved, only with zero user-state dependents, and
/// never touches capture-bound rows, peer imports or other sources.
public enum LegacyLocalSessionPurge {
    public static let predicateVersion = 1
    public static let auditKeyPrefix = "legacy_local_purge.v1."
    static let tokenPrefix = "engram-legacy-local-purge-v1\n"

    public struct SourceSummary: Codable, Equatable, Sendable {
        public let source: String
        public let sessions: Int
        public let newestIndexedAt: String?
        public let newestStartTime: String?
    }

    public struct Report: Codable, Equatable, Sendable {
        public let predicateVersion: Int
        public let sessionCount: Int
        public let planToken: String
        public let sources: [SourceSummary]
        public let blocking: [String: Int]
        public let derived: [String: Int]
        public let retained: [String: Int]
        public let captureBoundExcluded: Int
        public let otherLocalOriginSessions: [String: Int]
        public let purgeAllowed: Bool
    }

    public struct PurgeResult: Codable, Equatable, Sendable {
        public let planToken: String
        public let sessionsDeleted: Int
        public let deleted: [String: Int]
        public let auditKey: String
        public let purgedAt: String
    }

    public enum PurgeError: Error, Equatable, Sendable {
        case planChanged(sessionCount: Int, planToken: String)
        case blockingDependents([String: Int])
        case nothingToPurge
        case notInTransaction
        case verificationFailed(String)
    }

    /// Session-derived tables removed together with the candidate rows
    /// (report key, table). All are keyed by `session_id`; a missing table
    /// reports and deletes 0.
    static let derivedTables: [(key: String, table: String)] = [
        ("messages", "messages"),
        ("sessionsFts", "sessions_fts"),
        ("sessionsFtsRebuild", "sessions_fts_rebuild"),
        ("ftsMap", "fts_map"),
        ("sessionEmbeddings", "session_embeddings"),
        ("semanticChunks", "semantic_chunks"),
        ("sessionIndexJobs", "session_index_jobs"),
        ("sessionCosts", "session_costs"),
        ("sessionTools", "session_tools"),
        ("sessionWorkBeats", "session_work_beats"),
        ("sessionFiles", "session_files"),
        ("offloadQueue", "offload_queue"),
        ("rehydrateQueue", "rehydrate_queue"),
        ("syncLedger", "sync_ledger"),
    ]

    public static let blockingKeys = [
        "sessionLocalState",
        "rowCustomName",
        "rowHidden",
        "manualLinks",
        "externalConfirmedChildren",
        "externalSuggestedChildren",
        "sessionRelations",
        "favorites",
        "tags",
        "insights",
        "memoryInsights",
        "offloaded",
    ]

    private static let localOriginSQL = "COALESCE(NULLIF(TRIM(s.origin),''),'local')='local'"
    private static let localAuthoritySQL = "COALESCE(NULLIF(TRIM(s.authoritative_node),''),'local')='local'"

    /// Candidate IDs: grok/pi rows whose origin and authority are both local,
    /// outside the `remote:` capture/peer namespace, with no capture identity
    /// binding or generation. The capture FKs have no ON DELETE action, so a
    /// bound row could not be deleted even if this predicate admitted it.
    static func candidateSQL(_ db: Database) throws -> String {
        var sql = """
            SELECT s.id FROM sessions s
            WHERE s.source IN ('grok','pi')
              AND \(localOriginSQL)
              AND \(localAuthoritySQL)
              AND s.id NOT LIKE 'remote:%'
            """
        if try tableExists(db, "capture_ingest_identity_bindings") {
            sql += "\n  AND NOT EXISTS (SELECT 1 FROM capture_ingest_identity_bindings b WHERE b.stored_session_id=s.id)"
        }
        if try tableExists(db, "capture_ingest_generations") {
            sql += "\n  AND NOT EXISTS (SELECT 1 FROM capture_ingest_generations g WHERE g.stored_session_id=s.id)"
        }
        return sql
    }

    /// SHA-256 over `engram-legacy-local-purge-v1\n` followed by each sorted
    /// candidate ID and a newline (the same bytes `sqlite3 ... ORDER BY s.id`
    /// prints after the prefix, so an operator can recompute it).
    static func planToken(ids: [String]) -> String {
        ArchiveV2Hash.sha256(Data((tokenPrefix + ids.map { $0 + "\n" }.joined()).utf8))
    }

    /// SELECT-only dry-run report. Safe on a read-only connection.
    public static func report(_ db: Database) throws -> Report {
        let candidates = try candidateSQL(db)
        let ids = try String.fetchAll(db, sql: candidates + "\nORDER BY s.id")
        let sources = try Row.fetchAll(
            db,
            sql: """
                SELECT source, COUNT(*) AS n, MAX(indexed_at) AS newest_indexed, MAX(start_time) AS newest_start
                FROM sessions WHERE id IN (\(candidates))
                GROUP BY source ORDER BY source
                """
        ).map { row in
            SourceSummary(
                source: row["source"],
                sessions: row["n"],
                newestIndexedAt: row["newest_indexed"],
                newestStartTime: row["newest_start"]
            )
        }
        let blocking = try blockingCounts(db, candidates: candidates)
        let derived = try derivedCounts(db, candidates: candidates)
        var retained: [String: Int] = ["fileIndexState": 0, "aiAuditLog": 0]
        if try tableExists(db, "file_index_state") {
            retained["fileIndexState"] = try count(db, """
                SELECT COUNT(*) FROM file_index_state
                WHERE source IN ('grok','pi')
                  AND locator IN (
                    SELECT file_path FROM sessions WHERE id IN (\(candidates))
                    UNION
                    SELECT source_locator FROM sessions
                    WHERE id IN (\(candidates)) AND source_locator IS NOT NULL
                  )
                """)
        }
        if try tableHasColumn(db, table: "ai_audit_log", column: "session_id") {
            retained["aiAuditLog"] = try count(
                db, "SELECT COUNT(*) FROM ai_audit_log WHERE session_id IN (\(candidates))"
            )
        }
        let captureBoundExcluded = try captureBoundCount(db)
        var otherLocal: [String: Int] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT s.source AS source, COUNT(*) AS n FROM sessions s
            WHERE s.source NOT IN ('grok','pi') AND \(localOriginSQL)
            GROUP BY s.source
            """) {
            otherLocal[row["source"] as String] = row["n"] as Int
        }
        return Report(
            predicateVersion: predicateVersion,
            sessionCount: ids.count,
            planToken: planToken(ids: ids),
            sources: sources,
            blocking: blocking,
            derived: derived,
            retained: retained,
            captureBoundExcluded: captureBoundExcluded,
            otherLocalOriginSessions: otherLocal,
            purgeAllowed: !ids.isEmpty && blocking.values.allSatisfy { $0 == 0 }
        )
    }

    /// Deletes exactly the approved plan inside the caller's transaction.
    /// Any thrown error must roll that transaction back.
    public static func purge(
        _ db: Database,
        expectedSessionCount: Int,
        expectedPlanToken: String,
        purgedAt: String
    ) throws -> PurgeResult {
        guard db.isInsideTransaction else { throw PurgeError.notInTransaction }
        let current = try report(db)
        guard current.sessionCount == expectedSessionCount, current.planToken == expectedPlanToken else {
            throw PurgeError.planChanged(sessionCount: current.sessionCount, planToken: current.planToken)
        }
        let blocking = current.blocking.filter { $0.value != 0 }
        guard blocking.isEmpty else { throw PurgeError.blockingDependents(blocking) }
        guard current.sessionCount > 0 else { throw PurgeError.nothingToPurge }

        let candidates = try candidateSQL(db)
        // Derived rows first, while the candidate sessions still exist (the
        // same order as StartupBackfills' skipped-session artifact cleanup).
        var deleted: [String: Int] = [:]
        for entry in derivedTables {
            guard try tableHasColumn(db, table: entry.table, column: "session_id") else {
                deleted[entry.key] = 0
                continue
            }
            try db.execute(sql: "DELETE FROM \(entry.table) WHERE session_id IN (\(candidates))")
            deleted[entry.key] = db.changesCount
        }
        guard deleted == current.derived else {
            throw PurgeError.verificationFailed("derived deleted counts differ from the plan")
        }
        guard try derivedCounts(db, candidates: candidates).values.allSatisfy({ $0 == 0 }) else {
            throw PurgeError.verificationFailed("derived rows remain for purged sessions")
        }
        try db.execute(sql: "DELETE FROM sessions WHERE id IN (\(candidates))")
        let sessionsDeleted = db.changesCount
        guard sessionsDeleted == expectedSessionCount else {
            throw PurgeError.verificationFailed("deleted session count differs from the plan")
        }
        guard try count(db, "SELECT COUNT(*) FROM (\(candidates))") == 0 else {
            throw PurgeError.verificationFailed("candidate sessions remain")
        }

        let auditKey = auditKeyPrefix + purgedAt
        let audit = AuditRecord(
            predicateVersion: predicateVersion,
            planToken: current.planToken,
            sessionCount: sessionsDeleted,
            sources: current.sources,
            deleted: deleted,
            purgedAt: purgedAt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try db.execute(
            sql: "INSERT INTO metadata(key, value) VALUES (?, ?)",
            arguments: [auditKey, String(decoding: try encoder.encode(audit), as: UTF8.self)]
        )
        return PurgeResult(
            planToken: current.planToken,
            sessionsDeleted: sessionsDeleted,
            deleted: deleted,
            auditKey: auditKey,
            purgedAt: purgedAt
        )
    }

    private struct AuditRecord: Encodable {
        let predicateVersion: Int
        let planToken: String
        let sessionCount: Int
        let sources: [SourceSummary]
        let deleted: [String: Int]
        let purgedAt: String
    }

    private static func blockingCounts(_ db: Database, candidates: String) throws -> [String: Int] {
        let inCandidates = "IN (\(candidates))"
        var counts = Dictionary(uniqueKeysWithValues: blockingKeys.map { ($0, 0) })
        if try tableHasColumn(db, table: "session_local_state", column: "session_id") {
            counts["sessionLocalState"] = try count(
                db, "SELECT COUNT(*) FROM session_local_state WHERE session_id \(inCandidates)"
            )
        }
        counts["rowCustomName"] = try count(db, """
            SELECT COUNT(*) FROM sessions
            WHERE id \(inCandidates) AND TRIM(COALESCE(custom_name,'')) != ''
            """)
        counts["rowHidden"] = try count(
            db, "SELECT COUNT(*) FROM sessions WHERE id \(inCandidates) AND hidden_at IS NOT NULL"
        )
        counts["manualLinks"] = try count(
            db, "SELECT COUNT(*) FROM sessions WHERE id \(inCandidates) AND link_source = 'manual'"
        )
        counts["externalConfirmedChildren"] = try count(db, """
            SELECT COUNT(*) FROM sessions
            WHERE parent_session_id \(inCandidates) AND id NOT \(inCandidates)
            """)
        counts["externalSuggestedChildren"] = try count(db, """
            SELECT COUNT(*) FROM sessions
            WHERE suggested_parent_id \(inCandidates) AND id NOT \(inCandidates)
            """)
        if try tableExists(db, "session_relations") {
            counts["sessionRelations"] = try count(db, """
                SELECT COUNT(*) FROM session_relations
                WHERE a_id \(inCandidates) OR b_id \(inCandidates)
                """)
        }
        for (key, table) in [("favorites", "favorites"), ("tags", "tags")] {
            if try tableHasColumn(db, table: table, column: "session_id") {
                counts[key] = try count(db, "SELECT COUNT(*) FROM \(table) WHERE session_id \(inCandidates)")
            }
        }
        for (key, table) in [("insights", "insights"), ("memoryInsights", "memory_insights")] {
            if try tableHasColumn(db, table: table, column: "source_session_id") {
                counts[key] = try count(
                    db, "SELECT COUNT(*) FROM \(table) WHERE source_session_id \(inCandidates)"
                )
            }
        }
        counts["offloaded"] = try count(db, """
            SELECT COUNT(*) FROM sessions
            WHERE id \(inCandidates) AND COALESCE(offload_state,'local') != 'local'
            """)
        return counts
    }

    private static func derivedCounts(_ db: Database, candidates: String) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for entry in derivedTables {
            guard try tableHasColumn(db, table: entry.table, column: "session_id") else {
                counts[entry.key] = 0
                continue
            }
            counts[entry.key] = try count(
                db, "SELECT COUNT(*) FROM \(entry.table) WHERE session_id IN (\(candidates))"
            )
        }
        return counts
    }

    private static func captureBoundCount(_ db: Database) throws -> Int {
        var bound: [String] = []
        if try tableExists(db, "capture_ingest_identity_bindings") {
            bound.append("EXISTS (SELECT 1 FROM capture_ingest_identity_bindings b WHERE b.stored_session_id=s.id)")
        }
        if try tableExists(db, "capture_ingest_generations") {
            bound.append("EXISTS (SELECT 1 FROM capture_ingest_generations g WHERE g.stored_session_id=s.id)")
        }
        guard !bound.isEmpty else { return 0 }
        return try count(db, """
            SELECT COUNT(*) FROM sessions s
            WHERE s.source IN ('grok','pi')
              AND \(localOriginSQL)
              AND \(localAuthoritySQL)
              AND (\(bound.joined(separator: " OR ")))
            """)
    }

    private static func count(_ db: Database, _ sql: String) throws -> Int {
        try Int.fetchOne(db, sql: sql) ?? 0
    }

    private static func tableExists(_ db: Database, _ table: String) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
            arguments: [table]
        ) ?? false
    }

    private static func tableHasColumn(_ db: Database, table: String, column: String) throws -> Bool {
        guard try tableExists(db, table) else { return false }
        return try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
            .contains { ($0["name"] as String?) == column }
    }
}
