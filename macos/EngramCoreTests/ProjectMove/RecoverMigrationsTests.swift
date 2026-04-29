// macos/EngramCoreTests/ProjectMove/RecoverMigrationsTests.swift
// Mirrors the recover-side coverage of tests/core/project-move/undo-recover.test.ts
// (recommendation strings, FS probing, includeCommitted).
import Foundation
import XCTest
@testable import EngramCoreWrite

final class RecoverMigrationsTests: XCTestCase {

    // MARK: - state filter

    func testExcludesCommittedByDefault() throws {
        let capturedStates = CapturedStates()
        let log = StubLog(records: []) { states, _ in capturedStates.set(states) }
        _ = try RecoverMigrations.diagnose(log: log)
        XCTAssertEqual(capturedStates.value, ["fs_pending", "fs_done", "failed"])
    }

    func testIncludesCommittedWhenRequested() throws {
        let capturedStates = CapturedStates()
        let log = StubLog(records: []) { states, _ in capturedStates.set(states) }
        _ = try RecoverMigrations.diagnose(
            log: log,
            options: RecoverOptions(includeCommitted: true)
        )
        XCTAssertEqual(
            capturedStates.value,
            ["fs_pending", "fs_done", "failed", "committed"]
        )
    }

    // MARK: - recommendations (the bulk of the contract)

    func testFsPendingRecommendationsByPathState() {
        XCTAssertTrue(recommendation(state: "fs_pending", old: true, new: false)
            .contains("FS untouched"))
        XCTAssertTrue(recommendation(state: "fs_pending", old: true, new: true)
            .contains("partial fs.cp"))
        XCTAssertTrue(recommendation(state: "fs_pending", old: false, new: true)
            .contains("DB log did not catch up"))
        XCTAssertTrue(recommendation(state: "fs_pending", old: false, new: false)
            .contains("Restore from backup"))
    }

    func testFsDoneRecommendationsByPathState() {
        let onlyNew = recommendation(state: "fs_done", old: false, new: true)
        XCTAssertTrue(onlyNew.contains("DB commit failed"))
        XCTAssertTrue(onlyNew.contains("WILL NOT work"))

        XCTAssertTrue(recommendation(state: "fs_done", old: true, new: true)
            .contains("partially undone"))
    }

    func testFailedRecommendationsByPathState() {
        XCTAssertTrue(recommendation(state: "failed", old: true, new: false)
            .contains("Compensation succeeded"))
        XCTAssertTrue(recommendation(state: "failed", old: false, new: true)
            .contains("did not reverse the FS"))
        XCTAssertTrue(recommendation(state: "failed", old: true, new: true)
            .contains("partially"))
        XCTAssertTrue(recommendation(state: "failed", old: false, new: false)
            .contains("data loss"))
    }

    func testCommittedRecommendationsByPathState() {
        XCTAssertEqual(
            recommendation(state: "committed", old: false, new: true),
            "OK — move completed as logged."
        )
        XCTAssertTrue(
            recommendation(state: "committed", old: true, new: false)
                .contains("Anomaly")
        )
    }

    func testUnknownStateGetsGenericRecommendation() {
        XCTAssertEqual(
            recommendation(state: "unexpected-thing", old: true, new: true),
            "Unknown state"
        )
    }

    // MARK: - probe + temp-artifact wiring

    func testDiagnosisRoundTripsFieldsFromLog() throws {
        let row = MigrationLogRecord(
            id: "m-7",
            state: "fs_done",
            oldPath: "/parent/old",
            newPath: "/parent/new",
            startedAt: "T0",
            finishedAt: "T1",
            error: "synthetic",
            rolledBackOf: nil
        )
        let log = StubLog(records: [row])
        let diagnoses = try RecoverMigrations.diagnose(
            log: log,
            probePath: { _ in .absent },
            readDirectory: { _ in [] }
        )
        XCTAssertEqual(diagnoses.count, 1)
        let d = diagnoses[0]
        XCTAssertEqual(d.migrationId, "m-7")
        XCTAssertEqual(d.state, "fs_done")
        XCTAssertEqual(d.oldPath, "/parent/old")
        XCTAssertEqual(d.newPath, "/parent/new")
        XCTAssertEqual(d.error, "synthetic")
        XCTAssertEqual(d.oldPathProbe, .absent)
        XCTAssertEqual(d.newPathProbe, .absent)
    }

    func testTempArtifactScanFlagsKnownPrefixes() throws {
        let row = MigrationLogRecord(
            id: "m-1",
            state: "failed",
            oldPath: "/parent/projA",
            newPath: "/parent/projB",
            startedAt: "T0"
        )
        let log = StubLog(records: [row])
        let diagnoses = try RecoverMigrations.diagnose(
            log: log,
            probePath: { _ in .absent },
            readDirectory: { dir in
                if dir == "/parent" {
                    return [
                        ".engram-tmp-1234-abc",
                        ".engram-move-tmp-5678-def",
                        "projB.engram-move-tmp-9999-ghi",
                        "projA.engram-move-tmp-1111-jkl",
                        "unrelated.txt",
                    ]
                }
                return []
            }
        )
        XCTAssertEqual(diagnoses.count, 1)
        let artifacts = diagnoses[0].tempArtifacts
        XCTAssertTrue(artifacts.contains("/parent/.engram-tmp-1234-abc"))
        XCTAssertTrue(artifacts.contains("/parent/.engram-move-tmp-5678-def"))
        XCTAssertTrue(artifacts.contains("/parent/projB.engram-move-tmp-9999-ghi"))
        XCTAssertTrue(artifacts.contains("/parent/projA.engram-move-tmp-1111-jkl"))
        XCTAssertFalse(artifacts.contains { $0.hasSuffix("/unrelated.txt") })
    }

    func testTempArtifactScanReportsErrorsWithoutCrashing() throws {
        let row = MigrationLogRecord(
            id: "m-1",
            state: "failed",
            oldPath: "/parent/projA",
            newPath: "/different/projB",
            startedAt: "T0"
        )
        let log = StubLog(records: [row])
        let diagnoses = try RecoverMigrations.diagnose(
            log: log,
            probePath: { _ in .absent },
            readDirectory: { dir in
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(EACCES),
                    userInfo: [NSLocalizedDescriptionKey: "denied"]
                )
            }
        )
        XCTAssertEqual(diagnoses.count, 1)
        XCTAssertTrue(diagnoses[0].tempArtifacts.isEmpty)
        XCTAssertNotNil(diagnoses[0].probeError)
        XCTAssertTrue(diagnoses[0].probeError?.contains("denied") ?? false)
    }

    func testRootParentsAreFilteredOut() throws {
        // Both paths share root parent "/" — must not get scanned.
        let row = MigrationLogRecord(
            id: "m-1",
            state: "failed",
            oldPath: "/old",
            newPath: "/new",
            startedAt: "T0"
        )
        let log = StubLog(records: [row])
        var dirsScanned: [String] = []
        _ = try RecoverMigrations.diagnose(
            log: log,
            probePath: { _ in .absent },
            readDirectory: { dir in
                dirsScanned.append(dir)
                return []
            }
        )
        XCTAssertFalse(dirsScanned.contains("/"), "root must not be scanned")
    }

    // MARK: - default probe

    func testDefaultProbeReturnsAbsentForMissingPath() {
        XCTAssertEqual(
            RecoverMigrations.defaultProbePath("/no/such/path/engram-test-\(UUID().uuidString)"),
            .absent
        )
    }

    func testDefaultProbeReturnsExistsForRealPath() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-recover-probe-\(UUID().uuidString)")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(RecoverMigrations.defaultProbePath(url.path), .exists)
    }

    // MARK: - helpers

    private func recommendation(state: String, old: Bool, new: Bool) -> String {
        let row = MigrationLogRecord(
            id: "m-1",
            state: state,
            oldPath: "/parent/old",
            newPath: "/parent/new",
            startedAt: "T0"
        )
        let log = StubLog(records: [row])
        let d = (try? RecoverMigrations.diagnose(
            log: log,
            options: RecoverOptions(includeCommitted: true),
            probePath: { path in
                if path == "/parent/old" { return old ? .exists : .absent }
                if path == "/parent/new" { return new ? .exists : .absent }
                return .absent
            },
            readDirectory: { _ in [] }
        )) ?? []
        return d.first?.recommendation ?? ""
    }
}

private final class CapturedStates: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String] = []

    var value: [String] {
        lock.withLock { states }
    }

    func set(_ states: [String]) {
        lock.withLock {
            self.states = states
        }
    }
}

private struct StubLog: MigrationLogReader {
    let records: [MigrationLogRecord]
    let onList: (@Sendable ([String], Date?) -> Void)?

    init(records: [MigrationLogRecord], onList: (@Sendable ([String], Date?) -> Void)? = nil) {
        self.records = records
        self.onList = onList
    }

    func find(migrationId: String) throws -> MigrationLogRecord? {
        records.first { $0.id == migrationId }
    }

    func list(states: [String], since: Date?) throws -> [MigrationLogRecord] {
        onList?(states, since)
        // Pass-through so tests can probe both the state-filter contract
        // (via `onList` capture) AND the recommendation builder's
        // defensive `default` branch with an unknown state.
        return records
    }
}
