import XCTest
@testable import Engram

/// Unit tests for the shared `RelativeTimeText` helper (wave-6 task 1).
final class RelativeTimeTextTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-06-01T12:00:00Z")!

    func testCompactMinutesHoursDaysBoundaries() {
        // Just under 60s → now
        XCTAssertEqual(
            RelativeTimeText.format("2026-06-01T11:59:30Z", style: .compact, now: now),
            "now"
        )
        // 60s → 1m
        XCTAssertEqual(
            RelativeTimeText.format("2026-06-01T11:59:00Z", style: .compact, now: now),
            "1m"
        )
        // Just under 1h stays minutes
        XCTAssertEqual(
            RelativeTimeText.format("2026-06-01T11:00:01Z", style: .compact, now: now),
            "59m"
        )
        // 1h boundary
        XCTAssertEqual(
            RelativeTimeText.format("2026-06-01T11:00:00Z", style: .compact, now: now),
            "1h"
        )
        // Just under 1d stays hours
        XCTAssertEqual(
            RelativeTimeText.format("2026-05-31T12:00:01Z", style: .compact, now: now),
            "23h"
        )
        // 1d boundary
        XCTAssertEqual(
            RelativeTimeText.format("2026-05-31T12:00:00Z", style: .compact, now: now),
            "1d"
        )
    }

    func testCompactUnparseableInputReturnsEmpty() {
        XCTAssertEqual(
            RelativeTimeText.format("not-a-date", style: .compact, now: now),
            ""
        )
        XCTAssertEqual(
            RelativeTimeText.format("", style: .compact, now: now),
            ""
        )
    }

    func testCompactParsesWholeSecondAndFractionalISO() {
        // Whole-second timestamps used to blank under SessionCard's fractional-only formatter.
        XCTAssertEqual(
            RelativeTimeText.format("2026-06-01T11:30:00Z", style: .compact, now: now),
            "30m"
        )
        XCTAssertEqual(
            RelativeTimeText.format("2026-06-01T10:00:00.000Z", style: .compact, now: now),
            "2h"
        )
    }

    func testAgoStyleDelegatesThroughTodayRelativeTime() {
        XCTAssertEqual(
            TodayRelativeTime.format("2026-06-01T11:30:00Z", now: now),
            "30m ago"
        )
        XCTAssertEqual(
            RelativeTimeText.format("2026-06-01T11:30:00Z", style: .ago, now: now),
            "30m ago"
        )
    }
}
