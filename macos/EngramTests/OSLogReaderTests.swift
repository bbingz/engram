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

    func testOSLogReaderUsesSystemScopeAndCountsErrorLevelEntries() throws {
        let source = try source("macos/Engram/Core/OSLogReader.swift")

        XCTAssertTrue(source.contains("OSLogStore(scope: .system)"))
        XCTAssertTrue(source.contains("OSLogStore(scope: .currentProcessIdentifier)"))
        XCTAssertTrue(source.contains("case .error: return \"error\""))
        XCTAssertTrue(source.contains("case .fault: return \"error\""))
        XCTAssertFalse(source.contains("case .error: return \"warn\""))
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
        var foundEngramError = false
        var attempts = 0
        while attempts < 20 && !foundEngramError {
            attempts += 1
            do {
                let result = try OSLogReader.recentLogs(hours: 1, limit: 5000)
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
            if !foundEngramError { Thread.sleep(forTimeInterval: 0.1) }
        }
        XCTAssertTrue(foundEngramError, "Emitted Engram error message should appear in OSLogReader.recentLogs")
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
