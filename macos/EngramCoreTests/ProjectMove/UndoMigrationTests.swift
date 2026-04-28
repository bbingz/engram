// macos/EngramCoreTests/ProjectMove/UndoMigrationTests.swift
// Mirrors the validation half of tests/core/project-move/undo-recover.test.ts.
// The full reverse-orchestrator integration tests land in Stage 4.
import Foundation
import XCTest
@testable import EngramCoreWrite

final class UndoMigrationTests: XCTestCase {

    // MARK: - validation

    func testHappyPathReturnsReverseRequest() throws {
        let log = StubMigrationLog(records: [
            "m-1": MigrationLogRecord(
                id: "m-1",
                state: "committed",
                oldPath: "/orig",
                newPath: "/renamed",
                startedAt: "T0",
                affectedSessionIds: ["abcdef12-3456"]
            ),
        ])
        let sessions = StubSessionReader(
            sessions: ["abcdef12-3456": SessionSnapshot(id: "abcdef12-3456", cwd: "/renamed")]
        )

        let request = try UndoMigration.prepareReverseRequest(
            migrationId: "m-1",
            log: log,
            sessions: sessions,
            fileExists: { $0 == "/renamed" }
        )
        XCTAssertEqual(request.originalMigrationId, "m-1")
        XCTAssertEqual(request.src, "/renamed")
        XCTAssertEqual(request.dst, "/orig")
    }

    func testNotFoundError() {
        let log = StubMigrationLog(records: [:])
        let sessions = StubSessionReader(sessions: [:])

        XCTAssertThrowsError(
            try UndoMigration.prepareReverseRequest(
                migrationId: "missing",
                log: log,
                sessions: sessions,
                fileExists: { _ in true }
            )
        ) { err in
            guard case UndoMigrationError.notFound(let id) = err else {
                return XCTFail("expected notFound, got \(err)")
            }
            XCTAssertEqual(id, "missing")
        }
    }

    func testRefusesToUndoNonCommittedStates() {
        let states = ["fs_pending", "fs_done", "failed", "weird-state"]
        for state in states {
            let log = StubMigrationLog(records: [
                "m": MigrationLogRecord(
                    id: "m",
                    state: state,
                    oldPath: "/a",
                    newPath: "/b",
                    startedAt: "T0"
                ),
            ])
            let sessions = StubSessionReader(sessions: [:])

            XCTAssertThrowsError(
                try UndoMigration.prepareReverseRequest(
                    migrationId: "m",
                    log: log,
                    sessions: sessions,
                    fileExists: { _ in true }
                )
            ) { err in
                guard let na = err as? UndoNotAllowedError else {
                    return XCTFail("expected UndoNotAllowedError for state=\(state), got \(err)")
                }
                XCTAssertEqual(na.state, state)
                XCTAssertEqual(na.errorName, "UndoNotAllowedError")
                XCTAssertEqual(
                    RetryPolicyClassifier.classify(errorName: na.errorName),
                    .never
                )
                XCTAssertEqual(na.errorDetails?.migrationId, "m")
                XCTAssertEqual(na.errorDetails?.state, state)
            }
        }
    }

    func testStaleErrorWhenNewPathMissing() {
        let log = StubMigrationLog(records: [
            "m": MigrationLogRecord(
                id: "m",
                state: "committed",
                oldPath: "/orig",
                newPath: "/renamed",
                startedAt: "T0"
            ),
        ])
        let sessions = StubSessionReader(sessions: [:])

        XCTAssertThrowsError(
            try UndoMigration.prepareReverseRequest(
                migrationId: "m",
                log: log,
                sessions: sessions,
                fileExists: { _ in false }
            )
        ) { err in
            guard let stale = err as? UndoStaleError else {
                return XCTFail("expected UndoStaleError, got \(err)")
            }
            XCTAssertEqual(stale.migrationId, "m")
            XCTAssertTrue(stale.reason.contains("/renamed"))
            XCTAssertEqual(stale.errorName, "UndoStaleError")
            XCTAssertEqual(
                RetryPolicyClassifier.classify(errorName: stale.errorName),
                .never
            )
        }
    }

    func testStaleErrorWhenAffectedSessionCwdDrifted() {
        let log = StubMigrationLog(records: [
            "m": MigrationLogRecord(
                id: "m",
                state: "committed",
                oldPath: "/orig",
                newPath: "/renamed",
                startedAt: "T0",
                affectedSessionIds: ["session-id-1234"]
            ),
        ])
        // session has been moved on by a later migration
        let sessions = StubSessionReader(
            sessions: ["session-id-1234": SessionSnapshot(id: "session-id-1234", cwd: "/somewhere/else")]
        )

        XCTAssertThrowsError(
            try UndoMigration.prepareReverseRequest(
                migrationId: "m",
                log: log,
                sessions: sessions,
                fileExists: { _ in true }
            )
        ) { err in
            guard let stale = err as? UndoStaleError else {
                return XCTFail("expected UndoStaleError, got \(err)")
            }
            XCTAssertTrue(
                stale.reason.contains("/somewhere/else"),
                "stale error must surface the drifted cwd: \(stale.reason)"
            )
            XCTAssertTrue(
                stale.reason.contains("session session-"),
                "stale error must include session id preview: \(stale.reason)"
            )
        }
    }

    func testNoStaleErrorWhenAffectedSessionMatchesNewPath() throws {
        let log = StubMigrationLog(records: [
            "m": MigrationLogRecord(
                id: "m",
                state: "committed",
                oldPath: "/orig",
                newPath: "/renamed",
                startedAt: "T0",
                affectedSessionIds: ["session-id-1234"]
            ),
        ])
        let sessions = StubSessionReader(
            sessions: ["session-id-1234": SessionSnapshot(id: "session-id-1234", cwd: "/renamed")]
        )
        let request = try UndoMigration.prepareReverseRequest(
            migrationId: "m",
            log: log,
            sessions: sessions,
            fileExists: { _ in true }
        )
        XCTAssertEqual(request.src, "/renamed")
    }

    func testEmptyAffectedSessionsSkipsCheck() throws {
        let log = StubMigrationLog(records: [
            "m": MigrationLogRecord(
                id: "m",
                state: "committed",
                oldPath: "/orig",
                newPath: "/renamed",
                startedAt: "T0",
                affectedSessionIds: []
            ),
        ])
        let request = try UndoMigration.prepareReverseRequest(
            migrationId: "m",
            log: log,
            sessions: StubSessionReader(sessions: [:]),
            fileExists: { _ in true }
        )
        XCTAssertEqual(request.dst, "/orig")
    }
}

// MARK: - test stubs

private struct StubMigrationLog: MigrationLogReader {
    let records: [String: MigrationLogRecord]
    func find(migrationId: String) throws -> MigrationLogRecord? { records[migrationId] }
    func list(states: [String], since: Date?) throws -> [MigrationLogRecord] {
        records.values.filter { states.contains($0.state) }
    }
}

private struct StubSessionReader: SessionByIdReader {
    let sessions: [String: SessionSnapshot]
    func session(id: String) throws -> SessionSnapshot? { sessions[id] }
}
