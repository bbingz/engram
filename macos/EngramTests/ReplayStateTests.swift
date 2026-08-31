// macos/EngramTests/ReplayStateTests.swift
import XCTest
@testable import Engram

@MainActor
final class ReplayStateTests: XCTestCase {

    private func entry(_ index: Int, _ timestamp: String?) -> ReplayTimelineEntry {
        ReplayTimelineEntry(
            index: index,
            role: "user",
            type: "message",
            preview: "msg \(index)",
            timestamp: timestamp,
            tokens: nil,
            durationToNextMs: nil
        )
    }

    // MARK: - parseISO tolerance

    func testParseISOToleratesFractionalAndNonFractional() {
        XCTAssertNotNil(ReplayState.parseISO("2026-06-14T10:00:00Z"))
        XCTAssertNotNil(ReplayState.parseISO("2026-06-14T10:00:00.123Z"))
        XCTAssertNil(ReplayState.parseISO("not-a-date"))
    }

    // MARK: - Density buckets

    func testDensityBucketsNonFlatForNonFractionalISO() {
        let state = ReplayState()
        // Clustered early, then spread to 10:10:00 — non-fractional timestamps.
        state.entries = [
            entry(0, "2026-06-14T10:00:00Z"),
            entry(1, "2026-06-14T10:00:05Z"),
            entry(2, "2026-06-14T10:00:10Z"),
            entry(3, "2026-06-14T10:10:00Z"),
        ]
        let buckets = state.densityBuckets
        XCTAssertEqual(buckets.reduce(0, +), 4, "all entries should land in a bucket")
        let nonEmpty = buckets.filter { $0 > 0 }.count
        XCTAssertGreaterThan(nonEmpty, 1, "non-fractional ISO timestamps must spread across buckets, not collapse to a flat/single bucket")
    }

    func testDensityBucketsNonFlatForFractionalISO() {
        let state = ReplayState()
        state.entries = [
            entry(0, "2026-06-14T10:00:00.000Z"),
            entry(1, "2026-06-14T10:00:05.250Z"),
            entry(2, "2026-06-14T10:00:10.500Z"),
            entry(3, "2026-06-14T10:10:00.000Z"),
        ]
        let buckets = state.densityBuckets
        XCTAssertEqual(buckets.reduce(0, +), 4)
        XCTAssertGreaterThan(buckets.filter { $0 > 0 }.count, 1)
    }

    func testDensityBucketsFlatWhenTimestampsUnparseable() {
        let state = ReplayState()
        state.entries = [entry(0, "garbage"), entry(1, "also-garbage")]
        XCTAssertEqual(state.densityBuckets, Array(repeating: 0, count: 100))
    }

    func testDensityBucketsClampOutOfOrderTimestamps() {
        let state = ReplayState()
        state.entries = [
            entry(0, "2026-06-14T10:00:00Z"),
            entry(1, "2026-06-14T09:59:00Z"),
            entry(2, "2026-06-14T10:10:00Z"),
        ]

        let buckets = state.densityBuckets

        XCTAssertEqual(buckets.reduce(0, +), 3)
        XCTAssertEqual(buckets[0], 2)
        XCTAssertEqual(buckets[99], 1)
    }

    func testTruncatedReplayStateDoesNotPresentPrefixAsComplete_repro() {
        let state = ReplayState()
        let entries = (0..<2_000).map { entry($0, nil) }

        state.replaceTimeline(entries, totalEntries: 2_001, hasMore: true)

        XCTAssertEqual(state.progress, "1 / 2000+")
        XCTAssertEqual(
            state.truncationNotice,
            "Showing first 2000 entries. At least 2001 exist."
        )

        state.seekTo(1_999)
        XCTAssertEqual(state.progress, "2000 / 2000+")
    }

    /// W8-5: the play/pause transport button's VoiceOver label must mirror the
    /// state the button will produce, not the icon's current glyph.
    func testPlayPauseLabelMirrorsState() {
        XCTAssertEqual(SessionReplayView.playPauseLabel(isPlaying: true), "Pause")
        XCTAssertEqual(SessionReplayView.playPauseLabel(isPlaying: false), "Play")
    }
}
