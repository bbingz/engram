import XCTest
@testable import Engram

final class SessionsFilterPersistenceTests: XCTestCase {
    func testSessionsTodayCutoffUsesInjectedDate_repro() {
        let formatter = ISO8601DateFormatter()
        let fixed = formatter.date(from: "2026-01-15T10:00:00Z")!
        let expected = formatter.string(from: Calendar.current.startOfDay(for: fixed))

        XCTAssertEqual(SessionsPageView.sinceDate(for: "Today", now: fixed), expected)
    }

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

    // Wave 6C-1: the HQ-only toggle persists under a dedicated key so a
    // Sessions-page default never collides with a user preference.
    func testHqOnlyKeyIsStable() {
        XCTAssertEqual(SessionsFilterPersistence.hqOnlyKey, "sessions.hqOnly")
        XCTAssertNotEqual(SessionsFilterPersistence.hqOnlyKey, SessionsFilterPersistence.sourceFilterKey)
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
