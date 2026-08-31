import Foundation
import GRDB
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

final class IndexAutoTitleTests: XCTestCase {
    private var tempDB: URL!
    private var writer: EngramDatabaseWriter!

    override func setUpWithError() throws {
        tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-title-\(UUID().uuidString).sqlite")
        writer = try EngramDatabaseWriter(path: tempDB.path)
        try writer.migrate()
    }

    override func tearDownWithError() throws {
        writer = nil
        if let tempDB { try? FileManager.default.removeItem(at: tempDB) }
        tempDB = nil
    }

    private func snapshot(
        id: String,
        summary: String? = nil,
        displayTitle: String? = nil,
        project: String? = nil,
        cwd: String = "/work/engram",
        startTime: String = "2026-05-23T10:00:00.000Z",
        hash: String = "h"
    ) -> AuthoritativeSessionSnapshot {
        AuthoritativeSessionSnapshot(
            id: id, source: .codex, authoritativeNode: "node", syncVersion: 1,
            snapshotHash: "\(hash)-\(id)", indexedAt: "2026-05-23T10:00:00Z",
            sourceLocator: "/tmp/\(id).jsonl", startTime: startTime, cwd: cwd,
            project: project, messageCount: 4, userMessageCount: 2,
            assistantMessageCount: 2, toolMessageCount: 0, systemMessageCount: 0,
            summary: summary, displayTitle: displayTitle, tier: .normal
        )
    }

    func testFreshIndexSetsGeneratedTitleFromSummaryFirstLine() throws {
        try writer.write { db in
            _ = try SessionSnapshotWriter(db: db)
                .writeAuthoritativeSnapshot(snapshot(id: "s1", summary: "Fix the login bug\nmore detail"))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id='s1'"),
                "Fix the login bug"
            )
        }
    }

    func testIndexRedactsSummaryAndDisplayTitleBeforePrefixing_repro() throws {
        let secret = "token:\n-----BEGIN PRIVATE KEY-----\n"
            + String(repeating: "A", count: 9_000)
            + "\n-----END PRIVATE KEY-----"
        try writer.write { db in
            _ = try SessionSnapshotWriter(db: db).writeAuthoritativeSnapshot(
                snapshot(id: "redacted-index-title", summary: secret, displayTitle: secret)
            )
            let row = try Row.fetchOne(
                db,
                sql: "SELECT summary, generated_title FROM sessions WHERE id = 'redacted-index-title'"
            )
            let summary: String = try XCTUnwrap(row?["summary"])
            let title: String = try XCTUnwrap(row?["generated_title"])
            for value in [summary, title] {
                XCTAssertTrue(value.contains(TranscriptRedactionPolicy.redactionToken), value)
                XCTAssertFalse(value.contains("BEGIN PRIVATE KEY"), value)
                XCTAssertFalse(value.contains("END PRIVATE KEY"), value)
                XCTAssertFalse(value.contains(String(repeating: "A", count: 64)), value)
            }
        }
    }

    func testCodexAdapterKeepsFullSecretUntilWriterRedactsThenPrefixes_repro() async throws {
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-redact-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: transcript) }
        let secret = "token:\n-----BEGIN PRIVATE KEY-----\n"
            + String(repeating: "A", count: 400)
            + "\n-----END PRIVATE KEY-----"
        let objects: [[String: Any]] = [
            [
                "type": "session_meta",
                "payload": [
                    "id": "adapter-redacted-index-title",
                    "timestamp": "2026-05-23T10:00:00Z",
                    "cwd": "/work/engram",
                ],
            ],
            [
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": secret]],
                ],
            ],
        ]
        let data = try objects.map { try JSONSerialization.data(withJSONObject: $0) }
            .reduce(into: Data()) { result, line in
                result.append(line)
                result.append(0x0A)
            }
        try data.write(to: transcript)
        let adapter = CodexAdapter(sessionsRoot: transcript.deletingLastPathComponent().path)
        guard case .success(let info) = try await adapter.parseSessionInfo(locator: transcript.path) else {
            return XCTFail("expected Codex parse success")
        }

        XCTAssertGreaterThan(info.summary?.count ?? 0, 200)
        try writer.write { db in
            _ = try SessionSnapshotWriter(db: db).writeAuthoritativeSnapshot(
                snapshot(id: info.id, summary: info.summary)
            )
            let summary = try XCTUnwrap(
                String.fetchOne(db, sql: "SELECT summary FROM sessions WHERE id = ?", arguments: [info.id])
            )
            XCTAssertTrue(summary.contains(TranscriptRedactionPolicy.redactionToken), summary)
            XCTAssertLessThanOrEqual(summary.count, 200)
            XCTAssertFalse(summary.contains(String(repeating: "A", count: 64)))
        }
    }

    func testSnapshotWriteRollsBackPartialWritesOnIndexJobFailure() throws {
        // Drop session_index_jobs so insertIndexJobs (the LAST write in the merge
        // sequence) fails AFTER the sessions upsert. upsertBatch catches a
        // per-snapshot error and still commits the batch transaction, so without
        // a per-snapshot savepoint the sessions row would be left advanced to the
        // new snapshot_hash with NO matching pending FTS job (search divergence).
        try writer.write { db in try db.execute(sql: "DROP TABLE session_index_jobs") }

        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            do {
                _ = try w.writeAuthoritativeSnapshot(snapshot(id: "s1", summary: "hello"))
                XCTFail("expected the index-job insert to throw (table dropped)")
            } catch {
                // Swallowed like upsertBatch does; the outer batch transaction commits.
            }
        }

        try writer.read { db in
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT id FROM sessions WHERE id='s1'"),
                "a snapshot whose index-job write failed must not leave a committed sessions row"
            )
        }
    }

    func testFreshIndexFallsBackToProjectAndDateWhenNoSummary() throws {
        try writer.write { db in
            _ = try SessionSnapshotWriter(db: db)
                .writeAuthoritativeSnapshot(snapshot(id: "s2", project: "engram"))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id='s2'"),
                "engram 2026-05-23"
            )
        }
    }

    func testReindexNeverClobbersExistingTitle() throws {
        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "s3", summary: "First title", hash: "h1"))
            // Simulate a user-set custom title living in generated_title.
            try db.execute(sql: "UPDATE sessions SET generated_title='User Edited' WHERE id='s3'")
            // Re-index with a changed snapshot (distinct hash forces the full
            // merge/upsert path, not a noop).
            let result = try w.writeAuthoritativeSnapshot(snapshot(id: "s3", summary: "Second title", hash: "h2"))
            XCTAssertEqual(result.action, .merge)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id='s3'"),
                "User Edited"
            )
        }
    }

    func testCursorReindexReplacesMechanicalFallbackWithNewSummary_repro() throws {
        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "cursor-title", project: "engram", hash: "h1"))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id='cursor-title'"),
                "engram 2026-05-23"
            )

            _ = try w.writeAuthoritativeSnapshot(
                snapshot(id: "cursor-title", summary: "Cursor fixed the login flow\nmore", project: "engram", hash: "h2")
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id='cursor-title'"),
                "Cursor fixed the login flow"
            )
        }
    }

    func testCursorReindexReplacesDateOnlyTitleWithProjectDateTitle_repro() throws {
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(
                snapshot(id: "cursor-project-title", project: nil, cwd: "", hash: "h1")
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id='cursor-project-title'"),
                "2026-05-23"
            )

            _ = try snapshotWriter.writeAuthoritativeSnapshot(
                snapshot(id: "cursor-project-title", project: "engram", cwd: "/work/engram", hash: "h2")
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id='cursor-project-title'"),
                "engram 2026-05-23"
            )
        }
    }

    func testCursorReindexReplacesFirstUserPreviewWithNewConversationDigest_repro() throws {
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(
                snapshot(
                    id: "cursor-preview-title",
                    summary: "First user asks about login",
                    project: "engram",
                    hash: "h1"
                )
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id='cursor-preview-title'"),
                "First user asks about login"
            )

            _ = try snapshotWriter.writeAuthoritativeSnapshot(
                snapshot(
                    id: "cursor-preview-title",
                    summary: "Resolved login token refresh race",
                    project: "engram",
                    hash: "h2"
                )
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id='cursor-preview-title'"),
                "Resolved login token refresh race"
            )
        }
    }

    func testCursorReindexReplacesMechanicalTitleAfterCwdOnlyMergeWithNestedDigest_repro() throws {
        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(id: "cursor-title-transition", project: nil, cwd: "", hash: "h1")
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id='cursor-title-transition'"),
                "2026-05-23"
            )

            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "cursor-title-transition",
                    project: nil,
                    cwd: "/work/engram",
                    hash: "h2"
                )
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id='cursor-title-transition'"),
                "engram 2026-05-23"
            )

            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "cursor-title-transition",
                    summary: "Nested Cursor digest\nwith detail",
                    displayTitle: "  Official Cursor title  ",
                    project: nil,
                    cwd: "/work/engram",
                    hash: "h3"
                )
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id='cursor-title-transition'"),
                "Official Cursor title"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT summary FROM sessions WHERE id='cursor-title-transition'"),
                "Nested Cursor digest\nwith detail"
            )
        }
    }

    func testCursorReindexReplacesMechanicalTitleWithDisplayTitleOnly_repro() throws {
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(
                snapshot(id: "cursor-display-title-only", project: nil, cwd: "", hash: "h1")
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id='cursor-display-title-only'"),
                "2026-05-23"
            )

            _ = try snapshotWriter.writeAuthoritativeSnapshot(
                snapshot(
                    id: "cursor-display-title-only",
                    displayTitle: "Official Cursor title",
                    project: nil,
                    cwd: "/work/engram",
                    hash: "h2"
                )
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id='cursor-display-title-only'"),
                "Official Cursor title"
            )
        }
    }

    func testCursorOfficialTitleReplacesStoredDigestWhenCustomNameIsEmpty_repro() throws {
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(
                snapshot(
                    id: "cursor-official-after-digest",
                    summary: "Nested digest title\nmore",
                    project: "engram",
                    hash: "h1"
                )
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id='cursor-official-after-digest'"),
                "Nested digest title"
            )

            _ = try snapshotWriter.writeAuthoritativeSnapshot(
                snapshot(
                    id: "cursor-official-after-digest",
                    summary: "Nested digest title\nmore",
                    displayTitle: "Official composer title",
                    project: "engram",
                    hash: "h2"
                )
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id='cursor-official-after-digest'"),
                "Official composer title"
            )
        }
    }
}
