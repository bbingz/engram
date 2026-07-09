import XCTest
@testable import Engram

final class SessionsFilterPersistenceTests: XCTestCase {
    func testSanitizeSessionAndTimeFilters() {
        XCTAssertEqual(SessionsFilterPersistence.sanitizeSessionFilter("Starred"), "Starred")
        XCTAssertEqual(SessionsFilterPersistence.sanitizeSessionFilter("bogus"), "All")
        XCTAssertEqual(SessionsFilterPersistence.sanitizeTimeFilter("Today"), "Today")
        XCTAssertEqual(SessionsFilterPersistence.sanitizeTimeFilter("yesterday"), "All Time")
    }

    func testOptionalSourceEmptySentinel() {
        XCTAssertNil(SessionsFilterPersistence.optionalSource(from: ""))
        XCTAssertNil(SessionsFilterPersistence.optionalSource(from: "  "))
        XCTAssertEqual(SessionsFilterPersistence.optionalSource(from: "claude-code"), "claude-code")
        XCTAssertEqual(SessionsFilterPersistence.storage(from: nil), "")
        XCTAssertEqual(SessionsFilterPersistence.storage(from: "codex"), "codex")
    }

    func testResolvedSourceFallsBackWhenUnavailable() {
        // Unknown source with a loaded catalog → clear filter (avoid empty page).
        XCTAssertNil(
            SessionsFilterPersistence.resolvedSource(
                stored: "gone-source",
                available: ["claude-code", "codex"]
            )
        )
        // Known source is kept.
        XCTAssertEqual(
            SessionsFilterPersistence.resolvedSource(
                stored: "codex",
                available: ["claude-code", "codex"]
            ),
            "codex"
        )
        // Catalog not loaded yet → keep preference for restore.
        XCTAssertEqual(
            SessionsFilterPersistence.resolvedSource(
                stored: "codex",
                available: []
            ),
            "codex"
        )
        XCTAssertEqual(
            SessionsFilterPersistence.sanitizedSourceStorage(
                stored: "gone-source",
                available: ["claude-code"]
            ),
            ""
        )
    }
}
