// macos/EngramCoreWrite/ProjectMove/MigrationLogStore.swift
// Mirrors src/core/db/migration-log-repo.ts + applyMigrationDb half of
// src/core/db/maintenance.ts (Node parity baseline).
//
// Three-phase migration_log write protocol:
//   Phase A: startMigration()    → state='fs_pending'  (BEFORE FS ops)
//   Phase B: markFsDone()        → state='fs_done'     (AFTER FS + JSONL patch)
//   Phase C: applyMigrationDb()  → state='committed'   (in DB transaction)
//   Failure: failMigration()     → state='failed'      (any non-terminal state)
//
// All functions take an open `GRDB.Database` so the orchestrator chooses
// the transaction boundary. `applyMigrationDb` opens its own nested savepoint
// inside the supplied connection.
import Foundation
import GRDB

public enum MigrationLogActor: String, Sendable {
    case cli
    case mcp
    case swiftUI = "swift-ui"
    case batch
}

public struct StartMigrationInput: Sendable {
    public var id: String
    public var oldPath: String
    public var newPath: String
    public var oldBasename: String
    public var newBasename: String
    public var dryRun: Bool
    public var auditNote: String?
    public var archived: Bool
    public var actor: MigrationLogActor
    public var rolledBackOf: String?

    public init(
        id: String,
        oldPath: String,
        newPath: String,
        oldBasename: String,
        newBasename: String,
        dryRun: Bool = false,
        auditNote: String? = nil,
        archived: Bool = false,
        actor: MigrationLogActor = .cli,
        rolledBackOf: String? = nil
    ) {
        self.id = id
        self.oldPath = oldPath
        self.newPath = newPath
        self.oldBasename = oldBasename
        self.newBasename = newBasename
        self.dryRun = dryRun
        self.auditNote = auditNote
        self.archived = archived
        self.actor = actor
        self.rolledBackOf = rolledBackOf
    }
}

public struct MarkFsDoneInput: Sendable {
    public var id: String
    public var filesPatched: Int
    public var occurrences: Int
    public var ccDirRenamed: Bool
    /// JSON-serializable detail map. Encoded with `JSONSerialization` so
    /// the column matches Node's `JSON.stringify` shape exactly.
    public var detail: [String: Any]?

    public init(
        id: String,
        filesPatched: Int,
        occurrences: Int,
        ccDirRenamed: Bool,
        detail: [String: Any]? = nil
    ) {
        self.id = id
        self.filesPatched = filesPatched
        self.occurrences = occurrences
        self.ccDirRenamed = ccDirRenamed
        self.detail = detail
    }
}

public struct ApplyMigrationInput: Sendable {
    public var migrationId: String
    public var oldPath: String
    public var newPath: String
    public var oldBasename: String
    public var newBasename: String

    public init(
        migrationId: String,
        oldPath: String,
        newPath: String,
        oldBasename: String,
        newBasename: String
    ) {
        self.migrationId = migrationId
        self.oldPath = oldPath
        self.newPath = newPath
        self.oldBasename = oldBasename
        self.newBasename = newBasename
    }
}

public struct ApplyMigrationResult: Equatable, Sendable {
    public let sessionsUpdated: Int
    public let localStateUpdated: Int
    public let aliasCreated: Bool

    public init(sessionsUpdated: Int, localStateUpdated: Int, aliasCreated: Bool) {
        self.sessionsUpdated = sessionsUpdated
        self.localStateUpdated = localStateUpdated
        self.aliasCreated = aliasCreated
    }
}

public enum MigrationLogStoreError: Error, Equatable {
    case sameOldNewPath(String)
    case notFound(id: String, op: String)
    case wrongState(id: String, current: String, expected: String, op: String)
}

public enum MigrationLogStore {

    /// Phase A. Inserts an `fs_pending` row.
    public static func startMigration(_ db: GRDB.Database, input: StartMigrationInput) throws {
        if input.oldPath == input.newPath {
            throw MigrationLogStoreError.sameOldNewPath(input.oldPath)
        }
        try db.execute(
            sql: """
            INSERT INTO migration_log (
                id, old_path, new_path, old_basename, new_basename,
                state, started_at, dry_run, audit_note, archived, actor, rolled_back_of
            )
            VALUES (
                ?, ?, ?, ?, ?,
                'fs_pending', datetime('now'), ?, ?, ?, ?, ?
            )
            """,
            arguments: [
                input.id,
                input.oldPath,
                input.newPath,
                input.oldBasename,
                input.newBasename,
                input.dryRun ? 1 : 0,
                input.auditNote,
                input.archived ? 1 : 0,
                input.actor.rawValue,
                input.rolledBackOf,
            ]
        )
    }

    /// Phase B. `fs_pending` → `fs_done`.
    public static func markFsDone(_ db: GRDB.Database, input: MarkFsDoneInput) throws {
        let detailJSON = try input.detail.map { try jsonString(from: $0) }
        try db.execute(
            sql: """
            UPDATE migration_log
               SET state = 'fs_done',
                   files_patched = ?,
                   occurrences = ?,
                   cc_dir_renamed = ?,
                   detail = ?
             WHERE id = ? AND state = 'fs_pending'
            """,
            arguments: [
                input.filesPatched,
                input.occurrences,
                input.ccDirRenamed ? 1 : 0,
                detailJSON,
                input.id,
            ]
        )
        if db.changesCount != 1 {
            try assertTransition(db, id: input.id, expected: ["fs_pending"], op: "markFsDone")
        }
    }

    /// Failure path. Any non-terminal state → `failed`. `error` is truncated
    /// to 2000 chars to match Node's parity slice.
    public static func failMigration(_ db: GRDB.Database, id: String, error: String) throws {
        let truncated = String(error.prefix(2000))
        try db.execute(
            sql: """
            UPDATE migration_log
               SET state = 'failed',
                   error = ?,
                   finished_at = datetime('now')
             WHERE id = ? AND state IN ('fs_pending', 'fs_done')
            """,
            arguments: [truncated, id]
        )
        if db.changesCount != 1 {
            try assertTransition(db, id: id, expected: ["fs_pending", "fs_done"], op: "failMigration")
        }
    }

    /// Phase C. Wraps sessions/local_state/alias rewrites + finishMigration in
    /// a savepoint inside the caller's transaction. Idempotent: a re-run on
    /// an already-`committed` row short-circuits with the cached counts so
    /// retries don't overwrite `sessions_updated=0`.
    public static func applyMigrationDb(
        _ db: GRDB.Database,
        input: ApplyMigrationInput
    ) throws -> ApplyMigrationResult {
        let migrationId = input.migrationId
        let oldPath = input.oldPath
        let newPath = input.newPath

        // Committed early-exit: if this migration has already been successfully
        // committed, return the cached counts instead of re-running the
        // transaction. Otherwise a retry would overwrite sessions_updated=0
        // (since no rows match the old path anymore).
        if let row = try Row.fetchOne(
            db,
            sql: "SELECT state, sessions_updated, alias_created FROM migration_log WHERE id = ?",
            arguments: [migrationId]
        ), (row["state"] as String?) == "committed" {
            return ApplyMigrationResult(
                sessionsUpdated: row["sessions_updated"] as Int? ?? 0,
                localStateUpdated: 0, // not tracked in log, irrelevant on replay
                aliasCreated: ((row["alias_created"] as Int?) ?? 0) != 0
            )
        }

        var sessionsUpdated = 0
        var localStateUpdated = 0
        var aliasCreated = false

        try db.inSavepoint {
            let pathArgs: StatementArguments = ["old": oldPath, "new": newPath]
            // 1a. Collect affected session ids BEFORE the UPDATE — Phase 3 undo
            // needs the authoritative list, not a prefix-reverse guess. Stored
            // in migration_log.detail.
            let affectedRows = try Row.fetchAll(
                db,
                sql: """
                SELECT id FROM sessions
                 WHERE \(pathMatch("source_locator"))
                    OR \(pathMatch("file_path"))
                    OR \(pathMatch("cwd"))
                """,
                arguments: pathArgs
            )
            let affectedSessionIds = affectedRows.compactMap { $0["id"] as String? }

            // 1b. Rewrite sessions path fields. We deliberately do NOT clear
            // orphan_* flags here (filesystem is the only truth — detectOrphans
            // decides orphan state based on actual isAccessible, not on path
            // rewrites).
            try db.execute(
                sql: """
                UPDATE sessions
                   SET source_locator = \(rewrite("source_locator")),
                       file_path      = \(rewrite("file_path")),
                       cwd            = \(rewrite("cwd"))
                 WHERE \(pathMatch("source_locator"))
                    OR \(pathMatch("file_path"))
                    OR \(pathMatch("cwd"))
                """,
                arguments: pathArgs
            )
            sessionsUpdated = db.changesCount

            // 2. Rewrite session_local_state.local_readable_path (UI read-priority field).
            try db.execute(
                sql: """
                UPDATE session_local_state
                   SET local_readable_path = \(rewrite("local_readable_path"))
                 WHERE \(pathMatch("local_readable_path"))
                """,
                arguments: pathArgs
            )
            localStateUpdated = db.changesCount

            // 3. Add project alias iff basenames differ (idempotent INSERT OR IGNORE).
            if input.oldBasename != input.newBasename
                && !input.oldBasename.isEmpty
                && !input.newBasename.isEmpty {
                let beforeCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM project_aliases WHERE alias = ? AND canonical = ?",
                    arguments: [input.oldBasename, input.newBasename]
                ) ?? 0
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO project_aliases (alias, canonical, created_at)
                    VALUES (?, ?, datetime('now'))
                    """,
                    arguments: [input.oldBasename, input.newBasename]
                )
                let afterCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM project_aliases WHERE alias = ? AND canonical = ?",
                    arguments: [input.oldBasename, input.newBasename]
                ) ?? 0
                aliasCreated = afterCount > beforeCount
            }

            // 4. Merge affected session ids into migration_log.detail. The row
            // already has a detail payload from Phase B (markFsDone); read-merge-write
            // so we don't lose it.
            let existingDetailRow = try Row.fetchOne(
                db,
                sql: "SELECT detail FROM migration_log WHERE id = ?",
                arguments: [migrationId]
            )
            var merged: [String: Any] = [:]
            if let detailString = existingDetailRow?["detail"] as String?,
               let detailData = detailString.data(using: .utf8),
               let parsed = try JSONSerialization.jsonObject(with: detailData) as? [String: Any] {
                merged = parsed
            }
            merged["affectedSessionIds"] = affectedSessionIds
            let mergedJSON = try jsonString(from: merged)
            try db.execute(
                sql: "UPDATE migration_log SET detail = ? WHERE id = ?",
                arguments: [mergedJSON, migrationId]
            )

            // 5. Mark migration_log state='committed'.
            try finishMigration(
                db,
                id: migrationId,
                sessionsUpdated: sessionsUpdated,
                aliasCreated: aliasCreated
            )

            return .commit
        }

        return ApplyMigrationResult(
            sessionsUpdated: sessionsUpdated,
            localStateUpdated: localStateUpdated,
            aliasCreated: aliasCreated
        )
    }

    /// Watcher guard: true if any non-terminal migration covers this path.
    /// Non-terminal = `fs_pending` / `fs_done`. Path "covers" iff equal OR
    /// startsWith `<column>/`. Substr prefix match avoids LIKE wildcards in
    /// paths containing `_` or `%`.
    public static func hasPendingMigrationFor(
        _ db: GRDB.Database,
        path: String,
        ttlSeconds: Int = 60 * 60
    ) throws -> Bool {
        guard !path.isEmpty else { return false }
        let cutoff = "-\(ttlSeconds) seconds"
        let row = try Row.fetchOne(
            db,
            sql: """
            SELECT 1 FROM migration_log
             WHERE state IN ('fs_pending', 'fs_done')
               AND started_at > datetime('now', ?)
               AND (
                    ? = old_path
                 OR (length(?) > length(old_path) AND substr(?, 1, length(old_path) + 1) = old_path || '/')
                 OR ? = new_path
                 OR (length(?) > length(new_path) AND substr(?, 1, length(new_path) + 1) = new_path || '/')
               )
             LIMIT 1
            """,
            arguments: [cutoff, path, path, path, path, path, path]
        )
        return row != nil
    }

    /// Convert migrations stuck in fs_pending/fs_done beyond the stale threshold
    /// to `failed`. Runs at daemon/MCP startup so crashed-process remnants
    /// don't accumulate. Returns the number of rows updated.
    @discardableResult
    public static func cleanupStaleMigrations(
        _ db: GRDB.Database,
        thresholdSeconds: Int = 24 * 60 * 60
    ) throws -> Int {
        let cutoff = "-\(thresholdSeconds) seconds"
        let hours = thresholdSeconds / 3600
        try db.execute(
            sql: """
            UPDATE migration_log
               SET state = 'failed',
                   error = 'stale_after_crash: non-terminal for over ' || ? || ' hours',
                   finished_at = datetime('now')
             WHERE state IN ('fs_pending', 'fs_done')
               AND started_at <= datetime('now', ?)
            """,
            arguments: [hours, cutoff]
        )
        return db.changesCount
    }

    // MARK: - internals

    /// `fs_done` → `committed`, internal to applyMigrationDb. Mirrors
    /// `finishMigration` from migration-log-repo.ts.
    private static func finishMigration(
        _ db: GRDB.Database,
        id: String,
        sessionsUpdated: Int,
        aliasCreated: Bool
    ) throws {
        try db.execute(
            sql: """
            UPDATE migration_log
               SET state = 'committed',
                   sessions_updated = ?,
                   alias_created = ?,
                   finished_at = datetime('now')
             WHERE id = ? AND state = 'fs_done'
            """,
            arguments: [sessionsUpdated, aliasCreated ? 1 : 0, id]
        )
        if db.changesCount != 1 {
            try assertTransition(db, id: id, expected: ["fs_done"], op: "finishMigration")
        }
    }

    private static func assertTransition(
        _ db: GRDB.Database,
        id: String,
        expected: [String],
        op: String
    ) throws -> Never {
        let current = try String.fetchOne(
            db,
            sql: "SELECT state FROM migration_log WHERE id = ?",
            arguments: [id]
        )
        guard let current else {
            throw MigrationLogStoreError.notFound(id: id, op: op)
        }
        throw MigrationLogStoreError.wrongState(
            id: id,
            current: current,
            expected: expected.joined(separator: "|"),
            op: op
        )
    }

    /// Path-match SQL fragment using substr boundary check. Caller binds
    /// `:old` once per execute; LIKE wildcards (`_`/`%`) are not interpreted.
    private static func pathMatch(_ col: String) -> String {
        "(\(col) = :old OR (LENGTH(\(col)) > LENGTH(:old) AND SUBSTR(\(col), 1, LENGTH(:old) + 1) = :old || '/'))"
    }

    /// Path-rewrite CASE expression using the same boundary check. Caller binds
    /// `:old` and `:new`.
    private static func rewrite(_ col: String) -> String {
        """
        CASE
          WHEN \(col) = :old THEN :new
          WHEN LENGTH(\(col)) > LENGTH(:old)
               AND SUBSTR(\(col), 1, LENGTH(:old) + 1) = :old || '/'
            THEN :new || SUBSTR(\(col), LENGTH(:old) + 1)
          ELSE \(col)
        END
        """
    }

    private static func jsonString(from object: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
