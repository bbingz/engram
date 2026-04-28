// macos/EngramCoreTests/ProjectMove/MigrationLogStoreTests.swift
// Tests for the GRDB-backed migration_log writer (Stage 4.1).
// Mirrors the contract of tests/core/db/migration-log-repo.test.ts +
// applyMigrationDb covered in tests/core/db/maintenance.test.ts.
import Foundation
import GRDB
import XCTest
@testable import EngramCoreWrite

final class MigrationLogStoreTests: XCTestCase {
    private var tempDB: URL!
    private var writer: EngramDatabaseWriter!

    override func setUpWithError() throws {
        tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-log-store-\(UUID().uuidString).sqlite")
        writer = try EngramDatabaseWriter(path: tempDB.path)
        try writer.migrate()
    }

    override func tearDownWithError() throws {
        writer = nil
        if let tempDB { try? FileManager.default.removeItem(at: tempDB) }
        tempDB = nil
    }

    // MARK: - startMigration

    func testStartMigrationInsertsFsPendingRow() throws {
        try writer.write { db in
            try MigrationLogStore.startMigration(
                db,
                input: StartMigrationInput(
                    id: "m1",
                    oldPath: "/x/old",
                    newPath: "/x/new",
                    oldBasename: "old",
                    newBasename: "new",
                    auditNote: "rename: marketing",
                    actor: .swiftUI
                )
            )

            let row = try Row.fetchOne(db, sql: "SELECT * FROM migration_log WHERE id = 'm1'")
            XCTAssertNotNil(row)
            XCTAssertEqual(row?["state"], "fs_pending")
            XCTAssertEqual(row?["old_path"], "/x/old")
            XCTAssertEqual(row?["new_path"], "/x/new")
            XCTAssertEqual(row?["old_basename"], "old")
            XCTAssertEqual(row?["new_basename"], "new")
            XCTAssertEqual(row?["audit_note"], "rename: marketing")
            XCTAssertEqual(row?["actor"], "swift-ui")
            XCTAssertEqual((row?["dry_run"] as Int?) ?? -1, 0)
            XCTAssertEqual((row?["archived"] as Int?) ?? -1, 0)
        }
    }

    func testStartMigrationRejectsSameOldAndNewPath() throws {
        try writer.write { db in
            XCTAssertThrowsError(
                try MigrationLogStore.startMigration(
                    db,
                    input: StartMigrationInput(
                        id: "m1",
                        oldPath: "/same",
                        newPath: "/same",
                        oldBasename: "same",
                        newBasename: "same"
                    )
                )
            ) { err in
                guard case MigrationLogStoreError.sameOldNewPath(let p) = err else {
                    return XCTFail("expected sameOldNewPath, got \(err)")
                }
                XCTAssertEqual(p, "/same")
            }
        }
    }

    // MARK: - markFsDone

    func testMarkFsDoneTransitionsAndStoresDetail() throws {
        try writer.write { db in
            try MigrationLogStore.startMigration(
                db,
                input: StartMigrationInput(
                    id: "m1",
                    oldPath: "/x/old",
                    newPath: "/x/new",
                    oldBasename: "old",
                    newBasename: "new"
                )
            )
            try MigrationLogStore.markFsDone(
                db,
                input: MarkFsDoneInput(
                    id: "m1",
                    filesPatched: 12,
                    occurrences: 47,
                    ccDirRenamed: true,
                    detail: ["move_strategy": "rename", "renamed_dirs": ["claude-code"]]
                )
            )

            let row = try Row.fetchOne(db, sql: "SELECT * FROM migration_log WHERE id = 'm1'")
            XCTAssertEqual(row?["state"], "fs_done")
            XCTAssertEqual(row?["files_patched"], 12)
            XCTAssertEqual(row?["occurrences"], 47)
            XCTAssertEqual((row?["cc_dir_renamed"] as Int?) ?? 0, 1)
            let detail = row?["detail"] as String?
            XCTAssertNotNil(detail)
            XCTAssertTrue(detail?.contains("\"move_strategy\":\"rename\"") ?? false, "unexpected detail: \(detail ?? "nil")")
        }
    }

    func testMarkFsDoneRejectsWrongStateWithDescriptiveError() throws {
        try writer.write { db in
            try MigrationLogStore.startMigration(
                db,
                input: StartMigrationInput(
                    id: "m1",
                    oldPath: "/old",
                    newPath: "/new",
                    oldBasename: "old",
                    newBasename: "new"
                )
            )
            try MigrationLogStore.failMigration(db, id: "m1", error: "boom")

            XCTAssertThrowsError(
                try MigrationLogStore.markFsDone(
                    db,
                    input: MarkFsDoneInput(id: "m1", filesPatched: 0, occurrences: 0, ccDirRenamed: false)
                )
            ) { err in
                guard case MigrationLogStoreError.wrongState(let id, let current, _, let op) = err else {
                    return XCTFail("expected wrongState, got \(err)")
                }
                XCTAssertEqual(id, "m1")
                XCTAssertEqual(current, "failed")
                XCTAssertEqual(op, "markFsDone")
            }
        }
    }

    func testMarkFsDoneOnUnknownIdSurfacesNotFound() throws {
        try writer.write { db in
            XCTAssertThrowsError(
                try MigrationLogStore.markFsDone(
                    db,
                    input: MarkFsDoneInput(id: "nope", filesPatched: 0, occurrences: 0, ccDirRenamed: false)
                )
            ) { err in
                guard case MigrationLogStoreError.notFound(let id, let op) = err else {
                    return XCTFail("expected notFound, got \(err)")
                }
                XCTAssertEqual(id, "nope")
                XCTAssertEqual(op, "markFsDone")
            }
        }
    }

    // MARK: - failMigration

    func testFailMigrationFromFsPendingTruncatesError() throws {
        try writer.write { db in
            try MigrationLogStore.startMigration(
                db,
                input: StartMigrationInput(
                    id: "m1",
                    oldPath: "/o",
                    newPath: "/n",
                    oldBasename: "o",
                    newBasename: "n"
                )
            )
            let huge = String(repeating: "x", count: 5_000)
            try MigrationLogStore.failMigration(db, id: "m1", error: huge)

            let row = try Row.fetchOne(db, sql: "SELECT state, error, finished_at FROM migration_log WHERE id = 'm1'")
            XCTAssertEqual(row?["state"], "failed")
            XCTAssertEqual((row?["error"] as String?)?.count, 2000, "error must be truncated to 2000 chars")
            XCTAssertNotNil(row?["finished_at"])
        }
    }

    func testFailMigrationFromAlreadyFailedRejects() throws {
        try writer.write { db in
            try MigrationLogStore.startMigration(
                db,
                input: StartMigrationInput(
                    id: "m1",
                    oldPath: "/o",
                    newPath: "/n",
                    oldBasename: "o",
                    newBasename: "n"
                )
            )
            try MigrationLogStore.failMigration(db, id: "m1", error: "first")

            XCTAssertThrowsError(
                try MigrationLogStore.failMigration(db, id: "m1", error: "second")
            ) { err in
                guard case MigrationLogStoreError.wrongState = err else {
                    return XCTFail("expected wrongState, got \(err)")
                }
            }
        }
    }

    // MARK: - applyMigrationDb

    func testApplyMigrationRewritesAllPathColumnsWithBoundary() throws {
        try writer.write { db in
            // Subtree match: should rewrite. Substring-but-not-subtree: must NOT rewrite.
            try insertSession(db, id: "exact",       cwd: "/a/proj")
            try insertSession(db, id: "subtree",     cwd: "/a/proj/sub")
            try insertSession(db, id: "lookalike",   cwd: "/a/projXX")  // /a/proj* should NOT match
            try insertSession(db, id: "unrelated",   cwd: "/zzz")
            try db.execute(sql: """
                INSERT INTO session_local_state(session_id, local_readable_path) VALUES
                  ('exact', '/a/proj'),
                  ('subtree', '/a/proj/sub'),
                  ('lookalike', '/a/projXX')
                """)

            try MigrationLogStore.startMigration(
                db,
                input: StartMigrationInput(
                    id: "m1",
                    oldPath: "/a/proj",
                    newPath: "/a/renamed",
                    oldBasename: "proj",
                    newBasename: "renamed"
                )
            )
            try MigrationLogStore.markFsDone(
                db,
                input: MarkFsDoneInput(id: "m1", filesPatched: 0, occurrences: 0, ccDirRenamed: false)
            )

            let result = try MigrationLogStore.applyMigrationDb(
                db,
                input: ApplyMigrationInput(
                    migrationId: "m1",
                    oldPath: "/a/proj",
                    newPath: "/a/renamed",
                    oldBasename: "proj",
                    newBasename: "renamed"
                )
            )

            XCTAssertEqual(result.sessionsUpdated, 2)
            XCTAssertEqual(result.localStateUpdated, 2)
            XCTAssertTrue(result.aliasCreated)

            // Path rewrites
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT cwd FROM sessions WHERE id='exact'"), "/a/renamed")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT cwd FROM sessions WHERE id='subtree'"), "/a/renamed/sub")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT cwd FROM sessions WHERE id='lookalike'"), "/a/projXX")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT cwd FROM sessions WHERE id='unrelated'"), "/zzz")

            // local_readable_path rewrites
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT local_readable_path FROM session_local_state WHERE session_id='exact'"), "/a/renamed")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT local_readable_path FROM session_local_state WHERE session_id='subtree'"), "/a/renamed/sub")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT local_readable_path FROM session_local_state WHERE session_id='lookalike'"), "/a/projXX")

            // alias inserted
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project_aliases WHERE alias='proj' AND canonical='renamed'"),
                1
            )

            // migration_log committed; affectedSessionIds merged into detail
            let row = try Row.fetchOne(db, sql: "SELECT state, sessions_updated, alias_created, detail, finished_at FROM migration_log WHERE id='m1'")
            XCTAssertEqual(row?["state"], "committed")
            XCTAssertEqual(row?["sessions_updated"], 2)
            XCTAssertEqual((row?["alias_created"] as Int?) ?? 0, 1)
            XCTAssertNotNil(row?["finished_at"])
            let detailString = row?["detail"] as String?
            let parsed = try JSONSerialization.jsonObject(
                with: detailString!.data(using: .utf8)!
            ) as? [String: Any]
            let affected = (parsed?["affectedSessionIds"] as? [String])?.sorted() ?? []
            XCTAssertEqual(affected, ["exact", "subtree"])
        }
    }

    func testApplyMigrationIsIdempotentForCommittedRow() throws {
        try writer.write { db in
            try insertSession(db, id: "s1", cwd: "/a/proj")
            try MigrationLogStore.startMigration(
                db,
                input: StartMigrationInput(
                    id: "m1", oldPath: "/a/proj", newPath: "/a/new",
                    oldBasename: "proj", newBasename: "new"
                )
            )
            try MigrationLogStore.markFsDone(
                db,
                input: MarkFsDoneInput(id: "m1", filesPatched: 0, occurrences: 0, ccDirRenamed: false)
            )
            let first = try MigrationLogStore.applyMigrationDb(
                db,
                input: ApplyMigrationInput(
                    migrationId: "m1", oldPath: "/a/proj", newPath: "/a/new",
                    oldBasename: "proj", newBasename: "new"
                )
            )
            XCTAssertEqual(first.sessionsUpdated, 1)

            // second call: row matches /a/new now, NOT /a/proj — early-exit returns cached
            let second = try MigrationLogStore.applyMigrationDb(
                db,
                input: ApplyMigrationInput(
                    migrationId: "m1", oldPath: "/a/proj", newPath: "/a/new",
                    oldBasename: "proj", newBasename: "new"
                )
            )
            XCTAssertEqual(second.sessionsUpdated, 1, "early-exit must report cached count, not 0")
            XCTAssertEqual(second.aliasCreated, true)
        }
    }

    func testApplyMigrationSkipsAliasWhenBasenamesEqual() throws {
        try writer.write { db in
            try insertSession(db, id: "s1", cwd: "/a/proj")
            try MigrationLogStore.startMigration(
                db,
                input: StartMigrationInput(
                    id: "m1", oldPath: "/a/proj", newPath: "/b/proj",
                    oldBasename: "proj", newBasename: "proj"
                )
            )
            try MigrationLogStore.markFsDone(
                db,
                input: MarkFsDoneInput(id: "m1", filesPatched: 0, occurrences: 0, ccDirRenamed: false)
            )
            let result = try MigrationLogStore.applyMigrationDb(
                db,
                input: ApplyMigrationInput(
                    migrationId: "m1", oldPath: "/a/proj", newPath: "/b/proj",
                    oldBasename: "proj", newBasename: "proj"
                )
            )
            XCTAssertFalse(result.aliasCreated)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project_aliases"),
                0
            )
        }
    }

    // MARK: - hasPendingMigrationFor

    func testHasPendingMigrationForUsesBoundaryMatch() throws {
        try writer.write { db in
            try MigrationLogStore.startMigration(
                db,
                input: StartMigrationInput(
                    id: "m1", oldPath: "/a/proj", newPath: "/a/new",
                    oldBasename: "proj", newBasename: "new"
                )
            )
            XCTAssertTrue(try MigrationLogStore.hasPendingMigrationFor(db, path: "/a/proj"))
            XCTAssertTrue(try MigrationLogStore.hasPendingMigrationFor(db, path: "/a/proj/sub/file"))
            XCTAssertTrue(try MigrationLogStore.hasPendingMigrationFor(db, path: "/a/new"))
            XCTAssertFalse(
                try MigrationLogStore.hasPendingMigrationFor(db, path: "/a/projXX"),
                "lookalike must not match"
            )
            XCTAssertFalse(
                try MigrationLogStore.hasPendingMigrationFor(db, path: "/different/path"),
                "unrelated path must not match"
            )
        }
    }

    func testHasPendingMigrationForIgnoresTerminalAndStaleRows() throws {
        try writer.write { db in
            try MigrationLogStore.startMigration(
                db,
                input: StartMigrationInput(
                    id: "committed", oldPath: "/x/p", newPath: "/x/q",
                    oldBasename: "p", newBasename: "q"
                )
            )
            try MigrationLogStore.markFsDone(
                db,
                input: MarkFsDoneInput(id: "committed", filesPatched: 0, occurrences: 0, ccDirRenamed: false)
            )
            _ = try MigrationLogStore.applyMigrationDb(
                db,
                input: ApplyMigrationInput(
                    migrationId: "committed", oldPath: "/x/p", newPath: "/x/q",
                    oldBasename: "p", newBasename: "q"
                )
            )
            XCTAssertFalse(
                try MigrationLogStore.hasPendingMigrationFor(db, path: "/x/p"),
                "committed migration must not block watcher"
            )

            // stale: insert with backdated started_at; ttl=1s; query must skip.
            try db.execute(
                sql: """
                INSERT INTO migration_log (id, old_path, new_path, old_basename, new_basename,
                  state, started_at)
                VALUES ('stale', '/y/old', '/y/new', 'old', 'new', 'fs_pending',
                        datetime('now', '-1 hour'))
                """
            )
            XCTAssertFalse(
                try MigrationLogStore.hasPendingMigrationFor(db, path: "/y/old", ttlSeconds: 1),
                "stale row past ttl must not block watcher"
            )
        }
    }

    // MARK: - cleanupStaleMigrations

    func testCleanupStaleMigrationsFlipsRowsBeyondThreshold() throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO migration_log (id, old_path, new_path, old_basename, new_basename,
                  state, started_at)
                VALUES
                  ('fresh',  '/a', '/b', 'a', 'b', 'fs_pending', datetime('now')),
                  ('stale1', '/c', '/d', 'c', 'd', 'fs_pending', datetime('now', '-30 hours')),
                  ('stale2', '/e', '/f', 'e', 'f', 'fs_done',    datetime('now', '-30 hours')),
                  ('done',   '/g', '/h', 'g', 'h', 'committed',  datetime('now', '-30 hours'))
                """
            )
            let changed = try MigrationLogStore.cleanupStaleMigrations(db)
            XCTAssertEqual(changed, 2, "fresh + committed rows must NOT be touched")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM migration_log WHERE id='fresh'"), "fs_pending")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM migration_log WHERE id='stale1'"), "failed")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM migration_log WHERE id='stale2'"), "failed")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM migration_log WHERE id='done'"), "committed")
        }
    }

    // MARK: - helpers

    private func insertSession(_ db: GRDB.Database, id: String, cwd: String) throws {
        try db.execute(
            sql: """
            INSERT INTO sessions(
              id, source, start_time, end_time, cwd, project, summary, file_path,
              source_locator
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                id, "codex", "2026-04-23T10:00:00.000Z", nil, cwd, nil, nil,
                "/tmp/\(id).jsonl", nil
            ]
        )
    }
}
