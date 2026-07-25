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
}
