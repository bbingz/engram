import XCTest
@testable import Engram

/// Rows 27/30 pure helpers for transcript-paging-timing (stacked on #247).
final class TranscriptPagingTimingTests: XCTestCase {
    private func msg(
        role: String,
        content: String,
        category: SystemCategory = .none,
        timestamp: String? = nil
    ) -> ChatMessage {
        ChatMessage(role: role, content: content, systemCategory: category, timestamp: timestamp)
    }

    // MARK: - Row 27 append-only rebuild

    func testAppendedPageMatchesFullBuild_repro() {
        let page1 = [
            msg(role: "user", content: "u1", timestamp: "2026-07-25T10:00:00Z"),
            msg(role: "assistant", content: "a1", timestamp: "2026-07-25T10:00:05Z"),
        ]
        let page2 = [
            msg(role: "user", content: "u2", timestamp: "2026-07-25T10:00:30Z"),
            msg(role: "assistant", content: "a2", timestamp: "2026-07-25T10:00:40Z"),
            msg(role: "assistant", content: "a2b", timestamp: "2026-07-25T10:00:41Z"),
            msg(role: "user", content: "u3", timestamp: "2026-07-25T10:01:00Z"),
            msg(role: "assistant", content: "a3", timestamp: "2026-07-25T10:01:10Z"),
        ]
        let full = IndexedMessage.build(from: page1 + page2)
        let first = IndexedMessage.build(from: page1)
        // Open turn on page1: no next user yet → chip nil until append backfill.
        XCTAssertNil(first.messages.first { $0.message.content == "a1" }?.turnDurationSeconds)

        let appended = IndexedMessage.appending(page2, to: first.messages, counts: first.counts)

        XCTAssertEqual(appended.messages.count, full.messages.count)
        XCTAssertEqual(appended.counts, full.counts)
        for (a, b) in zip(appended.messages, full.messages) {
            XCTAssertEqual(a.messageType, b.messageType)
            XCTAssertEqual(a.typeIndex, b.typeIndex)
            XCTAssertEqual(a.message.content, b.message.content)
            XCTAssertEqual(
                a.turnDurationSeconds ?? -1,
                b.turnDurationSeconds ?? -1,
                accuracy: 0.01,
                "duration mismatch on \(a.message.content)"
            )
        }
        // typeIndex continues across the page seam.
        let userIndexes = appended.messages.filter { $0.messageType == .user }.map(\.typeIndex)
        XCTAssertEqual(userIndexes, [1, 2, 3])
        // Boundary single-row backfill closed a1 when u2 arrived.
        XCTAssertEqual(
            appended.messages.first { $0.message.content == "a1" }?.turnDurationSeconds ?? -1,
            30,
            accuracy: 0.01
        )
    }

    /// Append duration walk must stay O(page), not O(prefix): ISO parses scale
    /// with the new page (plus at most one prior boundary user), not the full prefix.
    func testAppendDurationWalkIsLinearInPageSize_repro() {
        // Strictly increasing timestamps for a clean prior build.
        let priorMessages: [ChatMessage] = (0..<200).flatMap { i -> [ChatMessage] in
            let base = 1_000_000 + i * 60
            return [
                msg(role: "user", content: "u\(i)", timestamp: iso(base)),
                msg(role: "assistant", content: "a\(i)", timestamp: iso(base + 10)),
            ]
        }
        let first = IndexedMessage.build(from: priorMessages)
        let page = [
            msg(role: "user", content: "u-new", timestamp: iso(1_000_000 + 200 * 60)),
            msg(role: "assistant", content: "a-new", timestamp: iso(1_000_000 + 200 * 60 + 10)),
            msg(role: "user", content: "u-new2", timestamp: iso(1_000_000 + 201 * 60)),
            msg(role: "assistant", content: "a-new2", timestamp: iso(1_000_000 + 201 * 60 + 10)),
        ]
        _ = IndexedMessage.appending(page, to: first.messages, counts: first.counts)
        // 1 prior boundary user + 2 new-page users = 3 ISO parses (not ~200).
        XCTAssertLessThanOrEqual(
            IndexedMessage.lastDurationWalkISOParses,
            8,
            "append must not re-parse the full prefix (got \(IndexedMessage.lastDurationWalkISOParses))"
        )
        XCTAssertGreaterThanOrEqual(IndexedMessage.lastDurationWalkISOParses, 2)
    }

    // MARK: - Row 30 turn duration

    func testTurnDurationKeysFirstAssistantAndHidesSkew_repro() {
        let messages = [
            msg(role: "user", content: "q1", timestamp: "2026-07-25T10:00:00Z"),
            msg(role: "assistant", content: "a1-first", timestamp: "2026-07-25T10:00:05Z"),
            msg(role: "assistant", content: "a1-second", timestamp: "2026-07-25T10:00:06Z"),
            msg(role: "user", content: "q2", timestamp: "2026-07-25T10:00:30Z"),
            msg(role: "assistant", content: "a2", timestamp: "2026-07-25T10:00:40Z"),
            // Clock skew: next user before previous — hide chip.
            msg(role: "user", content: "q3", timestamp: "2026-07-25T09:00:00Z"),
        ]
        let built = IndexedMessage.build(from: messages)
        let firstAssistant = built.messages.first { $0.message.content == "a1-first" }!
        let secondAssistant = built.messages.first { $0.message.content == "a1-second" }!
        let a2 = built.messages.first { $0.message.content == "a2" }!

        XCTAssertEqual(firstAssistant.turnDurationSeconds ?? -1, 30, accuracy: 0.01)
        XCTAssertNil(secondAssistant.turnDurationSeconds, "only first assistant of turn gets the chip")
        // a2 has no following user with valid positive delta
        XCTAssertNil(a2.turnDurationSeconds)
    }

    /// Missing / unparseable user timestamps never produce a chip (and do not
    /// invent a duration across the gap).
    func testMissingTimestampHidesChip() {
        let messages = [
            msg(role: "user", content: "q1", timestamp: "2026-07-25T10:00:00Z"),
            msg(role: "assistant", content: "a1", timestamp: "2026-07-25T10:00:05Z"),
            msg(role: "user", content: "q-missing", timestamp: nil),
            msg(role: "assistant", content: "a-missing", timestamp: "2026-07-25T10:00:20Z"),
            msg(role: "user", content: "q-bad", timestamp: "not-a-date"),
            msg(role: "assistant", content: "a-bad", timestamp: "2026-07-25T10:00:40Z"),
            msg(role: "user", content: "q2", timestamp: "2026-07-25T10:01:00Z"),
            msg(role: "assistant", content: "a2", timestamp: "2026-07-25T10:01:10Z"),
        ]
        let built = IndexedMessage.build(from: messages)
        // q1→q2 (skipping unparseable anchors) would be a long span; we must not
        // attach that to a1 just because middle users lacked timestamps. a1 has no
        // valid next-user anchor → nil. a-missing / a-bad also nil.
        XCTAssertNil(built.messages.first { $0.message.content == "a1" }?.turnDurationSeconds)
        XCTAssertNil(built.messages.first { $0.message.content == "a-missing" }?.turnDurationSeconds)
        XCTAssertNil(built.messages.first { $0.message.content == "a-bad" }?.turnDurationSeconds)
        // q2 is the last user — a2 has no following user.
        XCTAssertNil(built.messages.first { $0.message.content == "a2" }?.turnDurationSeconds)
    }

    func testTurnDurationFormatBuckets() {
        XCTAssertEqual(TurnDurationFormat.chip(4.8), "4.8s")
        XCTAssertEqual(TurnDurationFormat.chip(42), "42s")
        XCTAssertEqual(TurnDurationFormat.chip(185), "3m 5s")
        // Whole-minute edge: round once before split (119.6s → 2m 0s, not 1m 0s).
        XCTAssertEqual(TurnDurationFormat.chip(119.6), "2m 0s")
        XCTAssertFalse(TurnDurationFormat.chip(12).contains("calls"))
    }

    func testChatMessageTimestampDefaultNil() {
        let legacy = ChatMessage(role: "user", content: "x", systemCategory: .none)
        XCTAssertNil(legacy.timestamp)
        let stamped = ChatMessage(role: "user", content: "x", systemCategory: .none, timestamp: "t")
        XCTAssertEqual(stamped.timestamp, "t")
    }

    private func iso(_ epochSeconds: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochSeconds))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
