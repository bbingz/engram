import XCTest
@testable import Engram

/// Row 9 / Part B: hold last-good live sessions across a failed poll.
final class LiveSessionsHoldTests: XCTestCase {
    private func sampleSession(id: String, activityLevel: String = "active") -> EngramServiceLiveSessionInfo {
        EngramServiceLiveSessionInfo(
            source: "codex",
            sessionId: id,
            project: "engram",
            title: "Session \(id)",
            cwd: "/tmp/engram",
            filePath: "/tmp/\(id).jsonl",
            startedAt: "2026-07-25T00:00:00Z",
            model: "gpt-5",
            currentActivity: "coding",
            lastModifiedAt: "2026-07-25T00:01:00Z",
            activityLevel: activityLevel
        )
    }

    /// Repro: a failed poll must not blank the last-good list; freshness ages
    /// from the success stamp on the live-poll clock (not the status channel).
    func testFailedPollHoldsLastGoodAndAgesFreshness_repro() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var hold = LiveSessionsHold(liveWindow: 15)
        let a = sampleSession(id: "a")
        let b = sampleSession(id: "b", activityLevel: "idle")
        hold.succeeded([a, b], at: t0)

        // Simulated failed poll: no `succeeded` call.
        XCTAssertEqual(hold.sessions.map(\.sessionId), ["a", "b"])

        // Just past liveWindow, still inside 30-min TTL → stale.
        XCTAssertEqual(
            hold.freshness(now: t0.addingTimeInterval(16)),
            .stale(asOf: t0)
        )
        // Past TTL → expired; list still held until a successful poll replaces it.
        XCTAssertEqual(
            hold.freshness(now: t0.addingTimeInterval(EngramServiceStatusStore.staleUsefulInterval + 1)),
            .expired
        )
        XCTAssertEqual(hold.sessions.map(\.sessionId), ["a", "b"])
    }

    /// Repro: a failed poll must change the Equatable hold value so an `@State`
    /// owner invalidates and re-evaluates time-derived stale/expired freshness.
    func testFailedPollRecordsAttemptWithoutReplacingLastGood_repro() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let failedAt = t0.addingTimeInterval(16)
        let session = sampleSession(id: "held")
        var hold = LiveSessionsHold(liveWindow: 15)
        hold.succeeded([session], at: t0)
        let beforeFailure = hold

        hold.failed(at: failedAt)

        XCTAssertNotEqual(hold, beforeFailure, "failed poll must invalidate an @State hold owner")
        XCTAssertEqual(hold.sessions, [session], "failed poll must retain the last-good list")
        XCTAssertEqual(hold.lastSuccessAt, t0, "failed poll must not refresh the success clock")
        XCTAssertEqual(hold.lastAttemptAt, failedAt)
        XCTAssertEqual(hold.freshness(now: failedAt), .stale(asOf: t0))
    }

    /// Successful empty poll is not a failure: list clears and stays `.live`
    /// for a few seconds (real-render case), not only at exact timestamp equality.
    func testSuccessfulEmptyPollIsLiveWithinWindow() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var hold = LiveSessionsHold(liveWindow: 15)
        hold.succeeded([sampleSession(id: "gone")], at: t0.addingTimeInterval(-60))
        hold.succeeded([], at: t0)

        XCTAssertTrue(hold.sessions.isEmpty)
        // A few seconds later — within liveWindow — must still be live.
        XCTAssertEqual(hold.freshness(now: t0.addingTimeInterval(3)), .live)
    }

    /// Guards against reintroducing a single shared liveThreshold: a 30s-window
    /// hold stays live at age 29 while a 10s-window hold is already stale.
    func testLiveWindowIsPerHoldNotSharedConstant_repro() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let age: TimeInterval = 29
        let now = t0.addingTimeInterval(age)
        let sessions = [sampleSession(id: "x")]

        var hold30 = LiveSessionsHold(liveWindow: 30)
        hold30.succeeded(sessions, at: t0)
        XCTAssertEqual(
            hold30.freshness(now: now),
            .live,
            "30s-window site (popover/badge cadence) must still be .live at age 29"
        )

        var hold10 = LiveSessionsHold(liveWindow: 10)
        hold10.succeeded(sessions, at: t0)
        XCTAssertEqual(
            hold10.freshness(now: now),
            .stale(asOf: t0),
            "10s-window site must be .stale at age 29 — proves the window is per-hold"
        )
    }

    func testNeverSucceededIsExpired() {
        let hold = LiveSessionsHold(liveWindow: 15)
        XCTAssertEqual(hold.freshness(now: Date()), .expired)
        XCTAssertTrue(hold.sessions.isEmpty)
    }

    func testStaleUsefulIntervalIsExposedAndThirtyMinutes() {
        XCTAssertEqual(EngramServiceStatusStore.staleUsefulInterval, 30 * 60)
    }

    func testSharedAsOfTextFormat() {
        let date = Date(timeIntervalSince1970: 0) // 1970-01-01 00:00 UTC; formatter is local
        let text = ServiceDataFreshness.asOfText(date)
        XCTAssertTrue(text.hasPrefix("as of "), "shared helper must use the as-of caption shape")
        XCTAssertFalse(text.contains("as of as of"), "must not double-prefix")
    }

    // MARK: - MenuBarController.heldActiveCount (badge over-count trap)

    private func session(
        id: String,
        activityLevel: String?
    ) -> EngramServiceLiveSessionInfo {
        EngramServiceLiveSessionInfo(
            source: "codex",
            sessionId: id,
            project: "engram",
            title: "Session \(id)",
            cwd: "/tmp/engram",
            filePath: "/tmp/\(id).jsonl",
            startedAt: "2026-07-25T00:00:00Z",
            model: "gpt-5",
            currentActivity: activityLevel == "active" ? "coding" : nil,
            lastModifiedAt: "2026-07-25T00:01:00Z",
            activityLevel: activityLevel
        )
    }

    /// Full unfiltered list: 2 active + idle + recent + nil level (= 5).
    private func mixedHold(at t0: Date, liveWindow: TimeInterval = 45) -> LiveSessionsHold {
        var hold = LiveSessionsHold(liveWindow: liveWindow)
        hold.succeeded(
            [
                session(id: "a1", activityLevel: "active"),
                session(id: "a2", activityLevel: "active"),
                session(id: "idle", activityLevel: "idle"),
                session(id: "recent", activityLevel: "recent"),
                session(id: "nilLevel", activityLevel: nil),
            ],
            at: t0
        )
        return hold
    }

    /// Repro: hold stores the full list; badge must count only active or it
    /// over-counts vs a successful-poll badge (2 active ≠ 5 total).
    func testHeldActiveCountFiltersToActiveOnly_repro() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let hold = mixedHold(at: t0)
        XCTAssertEqual(hold.sessions.count, 5, "fixture must hold the full unfiltered list")
        XCTAssertEqual(
            MenuBarController.heldActiveCount(hold, now: t0.addingTimeInterval(5)),
            2,
            "held badge count must re-apply activityLevel == active (not sessions.count)"
        )
    }

    func testHeldActiveCountDropsToZeroWhenExpired() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let hold = mixedHold(at: t0)
        let pastTTL = t0.addingTimeInterval(EngramServiceStatusStore.staleUsefulInterval + 1)
        XCTAssertEqual(hold.freshness(now: pastTTL), .expired)
        XCTAssertEqual(
            MenuBarController.heldActiveCount(hold, now: pastTTL),
            0,
            "badge must drop the live dot only when the hold is expired"
        )
    }

    func testHeldActiveCountNeverSucceededIsZero() {
        let hold = LiveSessionsHold(liveWindow: 45)
        XCTAssertEqual(MenuBarController.heldActiveCount(hold, now: Date()), 0)
    }
}
