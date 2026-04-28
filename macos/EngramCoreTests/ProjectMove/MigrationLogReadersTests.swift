// macos/EngramCoreTests/ProjectMove/MigrationLogReadersTests.swift
// GRDB-backed MigrationLogReader / SessionByIdReader (Stage 4.1).
import Foundation
import GRDB
import XCTest
@testable import EngramCoreWrite

final class MigrationLogReadersTests: XCTestCase {
    private var tempDB: URL!
    private var writer: EngramDatabaseWriter!

    override func setUpWithError() throws {
        tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-log-readers-\(UUID().uuidString).sqlite")
        writer = try EngramDatabaseWriter(path: tempDB.path)
        try writer.migrate()
    }

    override func tearDownWithError() throws {
        writer = nil
        if let tempDB { try? FileManager.default.removeItem(at: tempDB) }
        tempDB = nil
    }

    // MARK: - GRDBMigrationLogReader.find

    func testFindReturnsNilForUnknownId() throws {
        let reader = GRDBMigrationLogReader(writer: writer)
        XCTAssertNil(try reader.find(migrationId: "nope"))
    }

    func testFindRoundTripsAllScalarFieldsAndAffectedSessionIds() throws {
        try writer.write { db in
            try MigrationLogStore.startMigration(
                db,
                input: StartMigrationInput(
                    id: "m1",
                    oldPath: "/x/old",
                    newPath: "/x/new",
                    oldBasename: "old",
                    newBasename: "new",
                    rolledBackOf: "m0"
                )
            )
            try MigrationLogStore.markFsDone(
                db,
                input: MarkFsDoneInput(
                    id: "m1",
                    filesPatched: 1,
                    occurrences: 1,
                    ccDirRenamed: false,
                    detail: ["affectedSessionIds": ["s-a", "s-b"]]
                )
            )
            try MigrationLogStore.failMigration(db, id: "m1", error: "boom")
        }
        let reader = GRDBMigrationLogReader(writer: writer)
        let record = try reader.find(migrationId: "m1")
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.id, "m1")
        XCTAssertEqual(record?.state, "failed")
        XCTAssertEqual(record?.oldPath, "/x/old")
        XCTAssertEqual(record?.newPath, "/x/new")
        XCTAssertEqual(record?.error, "boom")
        XCTAssertEqual(record?.rolledBackOf, "m0")
        XCTAssertEqual(record?.affectedSessionIds.sorted(), ["s-a", "s-b"])
    }

    // MARK: - GRDBMigrationLogReader.list

    func testListAppliesStateFilterAndDescendingOrder() throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO migration_log (id, old_path, new_path, old_basename, new_basename,
                                           state, started_at)
                VALUES
                  ('a', '/p1', '/q1', 'p1', 'q1', 'fs_pending', '2026-04-01 10:00:00'),
                  ('b', '/p2', '/q2', 'p2', 'q2', 'committed',  '2026-04-02 10:00:00'),
                  ('c', '/p3', '/q3', 'p3', 'q3', 'fs_done',    '2026-04-03 10:00:00'),
                  ('d', '/p4', '/q4', 'p4', 'q4', 'failed',     '2026-04-04 10:00:00')
                """)
        }
        let reader = GRDBMigrationLogReader(writer: writer)
        let nonTerminal = try reader.list(states: ["fs_pending", "fs_done", "failed"], since: nil)
        XCTAssertEqual(nonTerminal.map(\.id), ["d", "c", "a"])
        let allCommitted = try reader.list(states: ["committed"], since: nil)
        XCTAssertEqual(allCommitted.map(\.id), ["b"])
        let none = try reader.list(states: ["committed"], since: dateFrom("2026-04-03 00:00:00"))
        XCTAssertEqual(none.map(\.id), [], "since filter must drop rows before threshold")
    }

    func testListSinceUsesUtcSqliteFormat() throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO migration_log (id, old_path, new_path, old_basename, new_basename,
                                           state, started_at)
                VALUES ('keep', '/a', '/b', 'a', 'b', 'committed', '2026-04-15 12:00:00')
                """)
        }
        let reader = GRDBMigrationLogReader(writer: writer)
        let cutoffBefore = dateFrom("2026-04-15 11:00:00")
        let cutoffAfter  = dateFrom("2026-04-15 13:00:00")
        XCTAssertEqual(try reader.list(states: ["committed"], since: cutoffBefore).map(\.id), ["keep"])
        XCTAssertEqual(try reader.list(states: ["committed"], since: cutoffAfter).map(\.id), [])
    }

    // MARK: - GRDBSessionByIdReader

    func testSessionByIdReturnsNilWhenAbsent() throws {
        let reader = GRDBSessionByIdReader(writer: writer)
        XCTAssertNil(try reader.session(id: "nope"))
    }

    func testSessionByIdRoundTripsCwd() throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions(id, source, start_time, cwd, file_path)
                VALUES ('s-1', 'codex', '2026-04-23T10:00:00.000Z', '/some/cwd', '/tmp/s.jsonl')
                """
            )
        }
        let reader = GRDBSessionByIdReader(writer: writer)
        let snap = try reader.session(id: "s-1")
        XCTAssertEqual(snap?.id, "s-1")
        XCTAssertEqual(snap?.cwd, "/some/cwd")
    }

    // MARK: - parseAffectedSessionIds

    func testParseAffectedSessionIdsHandlesAllShapes() {
        XCTAssertEqual(MigrationLogReaderShared.parseAffectedSessionIds(nil), [])
        XCTAssertEqual(MigrationLogReaderShared.parseAffectedSessionIds(""), [])
        XCTAssertEqual(MigrationLogReaderShared.parseAffectedSessionIds("not json"), [])
        XCTAssertEqual(MigrationLogReaderShared.parseAffectedSessionIds("{}"), [])
        XCTAssertEqual(
            MigrationLogReaderShared.parseAffectedSessionIds("{\"affectedSessionIds\":[\"a\",\"b\"]}"),
            ["a", "b"]
        )
        XCTAssertEqual(
            MigrationLogReaderShared.parseAffectedSessionIds("{\"affectedSessionIds\":[]}"),
            []
        )
        XCTAssertEqual(
            MigrationLogReaderShared.parseAffectedSessionIds("{\"otherKey\":42}"),
            []
        )
    }

    private func dateFrom(_ s: String) -> Date {
        MigrationLogReaderShared.sqliteDatetimeFormatter.date(from: s)!
    }
}
