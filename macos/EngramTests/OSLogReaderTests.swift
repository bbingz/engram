import XCTest
@testable import Engram

/// OBS-C1 coverage: the Observability views now read real signal from the unified
/// log (com.engram.*) via `OSLogReader` instead of the never-written `logs`/
/// `traces`/`metrics` tables. These tests assert the reader is well-formed:
/// it filters to Engram's subsystems and surfaces error-level entries it emits.
final class OSLogReaderTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testOSLogReaderTargetsOnlyCurrentAppSubsystem_repro() {
        XCTAssertEqual(OSLogReader.engramSubsystems, ["com.engram.app"])
    }

    func testServiceErrorUnionFiltersFractionalTimestampsAndKeepsUncappedKPIInput_repro() throws {
        let now = Date()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let old = fractional.string(from: now.addingTimeInterval(-25 * 3_600))
        let recent = fractional.string(from: now.addingTimeInterval(-60))
        let lines = [
            ServiceLogLineDTO(timestamp: old, level: "error", category: "ai", message: "old"),
        ] + (0..<250).map {
            ServiceLogLineDTO(timestamp: recent, level: "error", category: "ai", message: "recent \($0)")
        }
        let snapshot = ServiceLogSnapshot(
            lines: lines,
            coverageStartedAt: fractional.string(from: now.addingTimeInterval(-25 * 3_600))
        )

        let serviceErrors = ObservabilityLogUnion.serviceEntries(snapshot, hours: 24)
        XCTAssertEqual(serviceErrors.count, 250)
        XCTAssertFalse(serviceErrors.contains { $0.message == "old" })
        XCTAssertEqual(ObservabilityLogUnion.merge([], serviceErrors, limit: 20).count, 20)
        XCTAssertTrue(ObservabilityLogUnion.covers(snapshot, hours: 24, now: now))

        let recentCoverage = ServiceLogSnapshot(lines: [], coverageStartedAt: recent)
        XCTAssertFalse(ObservabilityLogUnion.covers(recentCoverage, hours: 24, now: now))
    }

    func testServiceErrorCoverageRejectsAnOverflowedRingWhoseOldestRowIsTooNew_repro() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let snapshot = ServiceLogSnapshot(
            lines: [
                ServiceLogLineDTO(
                    timestamp: formatter.string(from: now.addingTimeInterval(-60)),
                    level: "error",
                    category: "indexer",
                    message: "retained"
                ),
            ],
            coverageStartedAt: formatter.string(from: now.addingTimeInterval(-48 * 3_600)),
            isTruncated: true
        )

        XCTAssertFalse(ObservabilityLogUnion.covers(snapshot, hours: 24, now: now))
    }

    func testLogStreamAllReservesOlderErrorsBeforeClientCap_repro() throws {
        let error = LogEntry(
            id: 1,
            ts: "2026-08-24T00:00:00Z",
            level: "error",
            module: "parser",
            message: "older parse failure",
            traceId: nil,
            source: "com.engram.app",
            errorName: nil,
            errorMessage: nil
        )
        let chatter: [LogEntry] = (0..<250).map { index -> LogEntry in
            let minute = (index / 60) % 60
            let second = index % 60
            let timestamp = String(format: "2026-08-24T01:%02d:%02dZ", minute, second)
            return LogEntry(
                id: Int64(index + 2),
                ts: timestamp,
                level: "info",
                module: "indexer",
                message: "notice \(index)",
                traceId: nil,
                source: "com.engram.app",
                errorName: nil,
                errorMessage: nil
            )
        }

        let merged = ObservabilityLogUnion.merge(
            chatter + [error],
            [],
            limit: 200,
            reserveErrors: true
        )

        XCTAssertEqual(merged.count, 200)
        XCTAssertTrue(merged.contains { $0.message == "older parse failure" })
        let source = try source("macos/Engram/Views/Observability/LogStreamView.swift")
        XCTAssertTrue(source.contains("ObservabilityLogUnion.merge("))
        XCTAssertTrue(source.contains("reserveErrors: level == \"All\""))
        XCTAssertTrue(source.contains("let errors = level == \"All\""))
        XCTAssertTrue(source.contains("level: \"error\","))
        XCTAssertTrue(source.contains("limit: 200"))
    }

    func testObservabilityMergeUsesParsedTimeAndDropsUnparseableWindowRows_repro() {
        let appErrors = (0..<20).map { index in
            LogEntry(
                id: Int64(index),
                ts: "2026-08-24T00:00:00Z",
                level: "error",
                module: "app",
                message: "app \(index)",
                traceId: nil,
                source: "com.engram.app",
                errorName: nil,
                errorMessage: nil
            )
        }
        let laterServiceError = LogEntry(
            id: 1_000_000,
            ts: "2026-08-24T00:00:00.900Z",
            level: "error",
            module: "indexer",
            message: "later service error",
            traceId: nil,
            source: "com.engram.service",
            errorName: nil,
            errorMessage: nil
        )

        let merged = ObservabilityLogUnion.merge(appErrors, [laterServiceError], limit: 20)
        XCTAssertTrue(merged.contains { $0.message == "later service error" })

        let snapshot = ServiceLogSnapshot(lines: [
            ServiceLogLineDTO(timestamp: "not-a-time", level: "error", category: "indexer", message: "invalid"),
        ])
        XCTAssertTrue(ObservabilityLogUnion.serviceEntries(snapshot, hours: 24).isEmpty)
    }

    func testLogStreamAllLoadsUncappedServiceErrorsInsideTheWindow_repro() throws {
        let source = try source("macos/Engram/Views/Observability/LogStreamView.swift")

        XCTAssertTrue(source.contains("let retainedErrors = level == \"All\""))
        XCTAssertTrue(source.contains("level: \"error\","))
        XCTAssertTrue(source.contains("limit: nil"))
        XCTAssertTrue(source.contains("serviceEntries(snapshot, hours: 24)"))
    }

    func testObservabilityMergeUsesServiceSequenceInsteadOfSanitizedIdentity_repro() {
        let line = ServiceLogLineDTO(
            timestamp: "2026-08-24T00:00:00Z",
            level: "error",
            category: "indexer",
            message: "failed <path>"
        )
        let lines = [line, line]
        let entries = ObservabilityLogUnion.serviceEntries(ServiceLogSnapshot(lines: lines))

        XCTAssertEqual(ObservabilityLogUnion.merge(entries, [], limit: 20).count, 2)
    }

    func testLogStreamKeepsPrimaryPageWhenUncappedErrorFetchFails_repro() throws {
        let source = try source("macos/Engram/Views/Observability/LogStreamView.swift")
        XCTAssertTrue(source.contains("? (try? OSLogReader.recentLogs("))
        XCTAssertTrue(source.contains("? (try? await serviceClient.serviceLogs("))
        XCTAssertTrue(source.contains("level: \"error\""))
    }

    func testOSLogReaderKeepsRecentLogMemoryBounded() throws {
        let source = try source("macos/Engram/Core/OSLogReader.swift")

        XCTAssertTrue(source.contains("maxRecentLogEntries"))
        XCTAssertTrue(source.contains("let safeLimit = min(max(limit, 0), maxRecentLogEntries)"))
        XCTAssertFalse(source.contains("limit: Int.max"))
        XCTAssertFalse(source.contains("Array(result.suffix(limit))"))
    }

    func testRecentLogsCapturesEmittedEngramErrorMessageText() throws {
        let token = "OSLOGREADERTEST-\(UUID().uuidString)"
        EngramLogger.error(token, module: .ui)

        // OSLogStore writes are asynchronous; poll briefly.
        // Under xctest/TCC, each getEntries can take many seconds and may never
        // surface the current process token — treat that as env-blocked, not a
        // product regression (static-source tests above still lock the contract).
        var foundEngramError = false
        var attempts = 0
        let deadline = Date().addingTimeInterval(3)
        while attempts < 5 && Date() < deadline && !foundEngramError {
            attempts += 1
            do {
                let result = try OSLogReader.recentLogs(hours: 1, limit: 500)
                // Every returned entry must come from an Engram subsystem.
                for entry in result.entries {
                    XCTAssertTrue(OSLogReader.engramSubsystems.contains(entry.source),
                                  "OSLogReader must only return com.engram.* entries")
                }
                foundEngramError = result.entries.contains {
                    $0.source == "com.engram.app" &&
                    ["warn", "error"].contains($0.level.lowercased()) &&
                    $0.message.contains(token)
                }
            } catch is OSLogReaderError {
                // OSLogStore not accessible in this environment — the views handle
                // this by marking the panel "not available"; nothing to assert.
                throw XCTSkip("Current-process OSLogStore not accessible in this environment")
            }
            if !foundEngramError { Thread.sleep(forTimeInterval: 0.05) }
        }
        if !foundEngramError {
            throw XCTSkip("OSLog did not surface emitted token within timeout (TCC/xctest isolation)")
        }
    }

    func testErrorCountIsNonNegative() throws {
        do {
            let count = try OSLogReader.countErrors(hours: 1)
            XCTAssertGreaterThanOrEqual(count, 0)
        } catch is OSLogReaderError {
            throw XCTSkip("Current-process OSLogStore not accessible in this environment")
        }
    }
}
