import Foundation
import GRDB

public enum CollectorSpoolGCError: String, Error, Equatable {
    case busy, invalidInput, unsupportedSchema, invalidEvidence, proofMissing, escrowMissing
    case scopeChanged, budgetExceeded, holdNotElapsed, unsafePath, ioFailure
    case spoolIntegrityBlocked, spoolRestoreRequired, privacyWithheld, unknownRun
}

/// Only an already-owned inventory queue can reach these tables.
enum CollectorSpoolGCJournal {
    static func migrate(_ db: Database) throws {
        if let version = try String.fetchOne(db, sql: "SELECT value FROM collector_metadata WHERE key='gc_schema_version'"), version != "1" {
            throw CollectorSpoolGCError.unsupportedSchema
        }
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS collector_gc_runs (
              run_id TEXT PRIMARY KEY, machine_id TEXT NOT NULL, scope_hash TEXT NOT NULL,
              approval_hash TEXT NOT NULL, evidence_bytes BLOB NOT NULL, state TEXT NOT NULL,
              created_at INTEGER NOT NULL, hold_until INTEGER NOT NULL,
              max_bytes INTEGER NOT NULL CHECK(max_bytes>=0), max_objects INTEGER NOT NULL CHECK(max_objects>=0),
              reserved_bytes INTEGER NOT NULL DEFAULT 0 CHECK(reserved_bytes>=0),
              reserved_objects INTEGER NOT NULL DEFAULT 0 CHECK(reserved_objects>=0),
              finalized_bytes INTEGER NOT NULL DEFAULT 0 CHECK(finalized_bytes>=0),
              CHECK(reserved_bytes<=max_bytes), CHECK(reserved_objects<=max_objects)
            );
            CREATE TABLE IF NOT EXISTS collector_gc_objects (
              run_id TEXT NOT NULL REFERENCES collector_gc_runs(run_id), digest TEXT NOT NULL,
              raw_bytes INTEGER NOT NULL CHECK(raw_bytes>0), reference_hash TEXT NOT NULL,
              quarantine_path TEXT NOT NULL, identity_bytes BLOB NOT NULL, state TEXT NOT NULL,
              residency_generation INTEGER NOT NULL, verified_at INTEGER NOT NULL,
              unlink_approval_hash TEXT, unlink_evidence_bytes BLOB,
              PRIMARY KEY(run_id,digest)
            );
            CREATE TABLE IF NOT EXISTS collector_spool_object_residency (
              digest TEXT PRIMARY KEY, raw_bytes INTEGER NOT NULL, state TEXT NOT NULL,
              run_id TEXT NOT NULL, quarantine_path TEXT NOT NULL, evidence_hash TEXT NOT NULL,
              verified_at INTEGER NOT NULL, generation INTEGER NOT NULL CHECK(generation>0)
            );
            INSERT INTO collector_metadata(key,value) VALUES('gc_schema_version','1')
              ON CONFLICT(key) DO NOTHING;
            """)
    }

    /// Three first-row probes: never inspect the source graph on a never-GC spool.
    static func hasState(_ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM collector_gc_runs)
                OR EXISTS(SELECT 1 FROM collector_gc_objects)
                OR EXISTS(SELECT 1 FROM collector_spool_object_residency)
            """) == true
    }

    static func residency(_ db: Database, _ digest: String) throws -> Row? {
        try Row.fetchOne(db, sql: "SELECT * FROM collector_spool_object_residency WHERE digest=?", arguments: [digest])
    }

    static func rows(_ db: Database, runID: String? = nil) throws -> [Row] {
        let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM collector_gc_objects") ?? 0
        guard count <= 250_000 else { throw CollectorSpoolGCError.budgetExceeded }
        if let runID {
            return try Row.fetchAll(db, sql: "SELECT * FROM collector_gc_objects WHERE run_id=? ORDER BY digest", arguments: [runID])
        }
        return try Row.fetchAll(db, sql: "SELECT * FROM collector_gc_objects ORDER BY run_id,digest")
    }

    static func markResident(_ db: Database, digest: String, now: Int64) throws {
        // Retain journal/evidence. A new materialization invalidates every old
        // unlink intent even when an extra quarantine copy still exists.
        try db.execute(sql: "UPDATE collector_gc_objects SET state='cancelled',verified_at=? WHERE digest=? AND state!='evicted'", arguments: [now, digest])
        try db.execute(sql: "UPDATE collector_spool_object_residency SET state='resident',generation=generation+1,verified_at=? WHERE digest=?", arguments: [now, digest])
    }

    static func setState(_ db: Database, runID: String, digest: String, from: String, to: String, now: Int64) throws {
        try db.execute(sql: "UPDATE collector_gc_objects SET state=?,verified_at=? WHERE run_id=? AND digest=? AND state=?",
            arguments: [to, now, runID, digest, from])
        guard db.changesCount == 1 else { throw CollectorSpoolGCError.scopeChanged }
        try db.execute(sql: """
            UPDATE collector_spool_object_residency SET state=?,verified_at=? WHERE digest=? AND run_id=? AND state=?
              AND generation=(SELECT residency_generation FROM collector_gc_objects WHERE run_id=? AND digest=?)
            """, arguments: [to, now, digest, runID, from, runID, digest])
        guard db.changesCount == 1 else { throw CollectorSpoolGCError.scopeChanged }
    }
}
