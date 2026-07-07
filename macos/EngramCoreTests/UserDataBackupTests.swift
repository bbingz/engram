import GRDB
import XCTest
@testable import EngramCoreWrite

final class UserDataBackupTests: XCTestCase {
    private var tempRoot: URL!
    private var tempDB: URL!
    private var backupDir: URL!
    private var writer: EngramDatabaseWriter!

    override func setUpWithError() throws {
        let repoTemp = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".engram-test-backups", isDirectory: true)
        tempRoot = repoTemp
            .appendingPathComponent("user-data-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        tempDB = tempRoot.appendingPathComponent("index.sqlite")
        backupDir = tempRoot.appendingPathComponent("backups", isDirectory: true)
        writer = try EngramDatabaseWriter(path: tempDB.path)
        try writer.migrate()
    }

    override func tearDownWithError() throws {
        writer = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        tempDB = nil
        backupDir = nil
    }

    func testBackupRoundTripCapturesOnlyIrreplaceableUserRows() throws {
        try seedIrreplaceableRows()

        let result = try writer.runUserDataBackupIfNeeded(
            environment: backupEnvironment(minInterval: 0),
            now: fixedDate("2026-07-07T01:02:03Z")
        )

        XCTAssertEqual(result.status, .created)
        let backupURL = try XCTUnwrap(result.backupURL)
        let backup = try DatabaseQueue(path: backupURL.path)
        try backup.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA quick_check"), "ok")
            XCTAssertEqual(try metaValue(db, "source_schema_version"), "1")
            XCTAssertEqual(try metaValue(db, "row_count_insights"), "1")
            XCTAssertEqual(try metaValue(db, "row_count_sessions"), "4")
            XCTAssertEqual(try metaValue(db, "row_count_session_local_state"), "1")
            XCTAssertEqual(try metaValue(db, "row_count_project_aliases"), "1")
            XCTAssertEqual(try metaValue(db, "row_count_migration_log"), "1")
            XCTAssertEqual(try metaValue(db, "row_count_favorites"), "1")
            XCTAssertEqual(try metaValue(db, "row_count_session_relations"), "1")

            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT content FROM insights WHERE id = 'insight-1'"),
                "Remember this"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'manual-child'"),
                "parent-1"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT link_source FROM sessions WHERE id = 'manual-child'"),
                "manual"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT hidden_at FROM sessions WHERE id = 'hidden-session'"),
                "2026-07-07T00:00:00Z"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT custom_name FROM sessions WHERE id = 'named-session'"),
                "Pinned name"
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT id FROM sessions WHERE id = 'auto-linked-child'"),
                "derived non-manual links must stay out of the user-data backup"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT custom_name FROM sessions WHERE id = 'auto-named-child'"),
                "Auto named"
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'auto-named-child'"),
                "custom names are user data, but derived non-manual parent links are not"
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT link_source FROM sessions WHERE id = 'auto-named-child'"),
                "custom names are user data, but derived non-manual parent links are not"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT custom_name FROM session_local_state WHERE session_id = 'local-state'"),
                "Local override"
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT name FROM pragma_table_info('session_local_state') WHERE name = 'local_readable_path'"),
                "local_readable_path is derived from source session paths and must stay out of user-data backups"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT canonical FROM project_aliases WHERE alias = '/old/project'"),
                "/new/project"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT new_path FROM migration_log WHERE id = 'migration-1'"),
                "/new/project"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT created_at FROM favorites WHERE session_id = 'manual-child'"),
                "2026-07-07T00:10:00Z"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT created_at FROM session_relations WHERE a_id = 'manual-child' AND b_id = 'related-peer'"),
                "2026-07-07T00:20:00Z"
            )
        }
    }

    func testFreshValidBackupSkipsUntilCadenceAllowsAnotherRun() throws {
        let first = try writer.runUserDataBackupIfNeeded(
            environment: backupEnvironment(),
            now: fixedDate("2026-07-07T01:00:00Z")
        )
        XCTAssertEqual(first.status, .created)

        let skipped = try writer.runUserDataBackupIfNeeded(
            environment: backupEnvironment(),
            now: fixedDate("2026-07-07T02:00:00Z")
        )
        XCTAssertEqual(skipped.status, .skippedFreshBackup)
        XCTAssertEqual(try backupFileNames().count, 1)

        let forced = try writer.runUserDataBackupIfNeeded(
            environment: backupEnvironment(minInterval: 0),
            now: fixedDate("2026-07-07T02:00:01Z")
        )
        XCTAssertEqual(forced.status, .created)
        XCTAssertEqual(try backupFileNames().count, 2)
    }

    func testRotationKeepsNewestSevenMatchingBackupsOnly() throws {
        let nonMatching = backupDir.appendingPathComponent("manual-note.sqlite")
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: nonMatching)

        for hour in 0..<8 {
            _ = try writer.runUserDataBackupIfNeeded(
                environment: backupEnvironment(minInterval: 0),
                now: fixedDate("2026-07-07T0\(hour):00:00Z")
            )
        }

        let names = try backupFileNames()
        XCTAssertEqual(names.count, 7)
        XCTAssertFalse(names.contains("user-data-20260707-000000.sqlite"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nonMatching.path))
    }

    func testRotationCountsOnlyValidMatchingBackups() throws {
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let invalid = backupDir.appendingPathComponent("user-data-20260707-080000.sqlite")
        let invalidQueue = try DatabaseQueue(path: invalid.path)
        try invalidQueue.write { db in
            try db.execute(sql: "CREATE TABLE wrong_schema(id INTEGER PRIMARY KEY)")
        }

        for hour in 0..<8 {
            _ = try writer.runUserDataBackupIfNeeded(
                environment: backupEnvironment(minInterval: 0),
                now: fixedDate("2026-07-07T0\(hour):00:00Z")
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: invalid.path))
        let validNames = try backupFileNames().filter { name in
            let url = backupDir.appendingPathComponent(name)
            return (try? UserDataBackup.validateBackup(at: url)) != nil
        }
        XCTAssertEqual(validNames.count, 7)
        XCTAssertFalse(validNames.contains("user-data-20260707-000000.sqlite"))
    }

    func testFailedValidationDeletesAttemptedBackupAndLeavesPriorBackupsUntouched() throws {
        let prior = try writer.runUserDataBackupIfNeeded(
            environment: backupEnvironment(minInterval: 0),
            now: fixedDate("2026-07-07T01:00:00Z")
        )
        let priorURL = try XCTUnwrap(prior.backupURL)

        let failed = try writer.runUserDataBackupIfNeeded(
            environment: backupEnvironment(minInterval: 0),
            now: fixedDate("2026-07-08T01:00:00Z"),
            validationHook: { _ in throw ForcedValidationError() }
        )

        XCTAssertEqual(failed.status, .failedValidation)
        let attemptedURL = try XCTUnwrap(failed.backupURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attemptedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: priorURL.path))
        XCTAssertEqual(try backupFileNames(), [priorURL.lastPathComponent])
        XCTAssertEqual(try allFileNames(), [priorURL.lastPathComponent])
    }

    private func seedIrreplaceableRows() throws {
        try writer.write { db in
            try insertSession(db, id: "parent-1")
            try insertSession(db, id: "manual-child", parentSessionID: "parent-1", linkSource: "manual")
            try insertSession(db, id: "auto-linked-child", parentSessionID: "parent-1", linkSource: "auto")
            try insertSession(
                db,
                id: "auto-named-child",
                parentSessionID: "parent-1",
                linkSource: "auto",
                customName: "Auto named"
            )
            try insertSession(db, id: "hidden-session", hiddenAt: "2026-07-07T00:00:00Z")
            try insertSession(db, id: "named-session", customName: "Pinned name")
            try insertSession(db, id: "local-state")
            try insertSession(db, id: "related-peer")

            try db.execute(
                sql: """
                INSERT INTO insights(id, content, wing, room, source_session_id, importance, has_embedding,
                  created_at, insight_type, superseded_by, last_accessed_at, access_count)
                VALUES ('insight-1', 'Remember this', 'ops', 'backups', 'manual-child', 9, 1,
                  '2026-07-07T00:00:00Z', 'semantic', NULL, '2026-07-07T00:00:00Z', 2)
                """
            )
            try db.execute(
                sql: """
                INSERT INTO session_local_state(session_id, hidden_at, custom_name, local_readable_path)
                VALUES ('local-state', '2026-07-07T00:30:00Z', 'Local override', '/derived/path.md')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO project_aliases(alias, canonical, created_at)
                VALUES ('/old/project', '/new/project', '2026-07-07T00:00:00Z')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO migration_log(id, old_path, new_path, old_basename, new_basename, started_at, actor, detail)
                VALUES ('migration-1', '/old/project', '/new/project', 'project', 'project-renamed',
                  '2026-07-07T00:00:00Z', 'cli', '{"kind":"move"}')
                """
            )
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS favorites (
                    session_id TEXT PRIMARY KEY,
                    created_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                CREATE TABLE IF NOT EXISTS session_relations (
                    a_id TEXT NOT NULL,
                    b_id TEXT NOT NULL,
                    created_at TEXT NOT NULL DEFAULT (datetime('now')),
                    PRIMARY KEY (a_id, b_id)
                );
                """)
            try db.execute(
                sql: "INSERT INTO favorites(session_id, created_at) VALUES ('manual-child', '2026-07-07T00:10:00Z')"
            )
            try db.execute(
                sql: """
                INSERT INTO session_relations(a_id, b_id, created_at)
                VALUES ('manual-child', 'related-peer', '2026-07-07T00:20:00Z')
                """
            )
        }
    }

    private func insertSession(
        _ db: Database,
        id: String,
        parentSessionID: String? = nil,
        linkSource: String? = nil,
        hiddenAt: String? = nil,
        customName: String? = nil
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO sessions(id, source, start_time, cwd, file_path, parent_session_id, link_source, hidden_at, custom_name)
            VALUES (?, 'codex', '2026-07-07T00:00:00Z', '/tmp/project', ?, ?, ?, ?, ?)
            """,
            arguments: [id, "/tmp/\(id).jsonl", parentSessionID, linkSource, hiddenAt, customName]
        )
    }

    private func backupEnvironment(minInterval: Int? = nil) -> [String: String] {
        var environment = ["ENGRAM_BACKUP_DIR": backupDir.path]
        if let minInterval {
            environment["ENGRAM_BACKUP_MIN_INTERVAL_SECONDS"] = "\(minInterval)"
        }
        return environment
    }

    private func fixedDate(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func backupFileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: backupDir.path)
            .filter { $0.hasPrefix("user-data-") && $0.hasSuffix(".sqlite") }
            .sorted()
    }

    private func allFileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: backupDir.path).sorted()
    }

    private func metaValue(_ db: Database, _ key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM backup_meta WHERE key = ?", arguments: [key])
    }

    private struct ForcedValidationError: Error {}
}
