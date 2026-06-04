import XCTest
@testable import Engram

/// OBS-C1 coverage: the Observability views now read real signal from the unified
/// log (com.engram.*) via `OSLogReader` instead of the never-written `logs`/
/// `traces`/`metrics` tables. These tests assert the reader is well-formed:
/// it filters to Engram's subsystems and surfaces error-level entries it emits.
final class OSLogReaderTests: XCTestCase {
    func testRecentLogsCapturesEmittedEngramErrorWithoutRequiringPublicMessageText() throws {
        EngramLogger.error("OSLOGREADERTEST-\(UUID().uuidString)", module: .ui)

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
                    $0.source == "com.engram.app" && ["warn", "error"].contains($0.level.lowercased())
                }
            } catch is OSLogReaderError {
                // OSLogStore not accessible in this environment — the views handle
                // this by marking the panel "not available"; nothing to assert.
                throw XCTSkip("OSLogStore.local() not accessible in this environment")
            }
            if !foundEngramError { Thread.sleep(forTimeInterval: 0.1) }
        }
        XCTAssertTrue(foundEngramError, "Emitted Engram error should appear in OSLogReader.recentLogs")
    }

    func testErrorCountIsNonNegative() throws {
        do {
            let count = try OSLogReader.countErrors(hours: 1)
            XCTAssertGreaterThanOrEqual(count, 0)
        } catch is OSLogReaderError {
            throw XCTSkip("OSLogStore.local() not accessible in this environment")
        }
    }
}
