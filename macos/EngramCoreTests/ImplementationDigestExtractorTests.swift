import EngramCoreRead
import XCTest

final class ImplementationDigestExtractorTests: XCTestCase {
    func testExtractsCompletionReportAndFiltersMachineTurns() {
        let messages = [
            NormalizedMessage(role: .user, content: "# AGENTS.md instructions for /Users/bing/-Code-/engram\n<INSTRUCTIONS>noise</INSTRUCTIONS>", timestamp: "2026-06-23T09:00:00Z"),
            NormalizedMessage(role: .user, content: "实现项目变更时间线第一版", timestamp: "2026-06-23T10:00:00Z"),
            NormalizedMessage(role: .assistant, content: "我先读现有实现，然后补测试。", timestamp: "2026-06-23T10:01:00Z"),
            NormalizedMessage(role: .assistant, content: """
            **结果**

            已实现第一版项目变更时间线。

            **改了什么**
            - 新增 work beat 抽取

            **验证结果**
            checks run: targeted tests
            """, timestamp: "2026-06-23T11:00:00Z"),
            NormalizedMessage(role: .user, content: "<task-notification><status>completed</status></task-notification>", timestamp: "2026-06-23T11:02:00Z"),
        ]

        let beats = ImplementationDigestExtractor.extract(messages: messages, sessionId: "s1", sessionTitle: "timeline session")

        XCTAssertEqual(beats.count, 1)
        XCTAssertEqual(beats[0].humanIntent, "实现项目变更时间线第一版")
        XCTAssertTrue(beats[0].assistantOutcome.contains("已实现第一版项目变更时间线"))
        XCTAssertEqual(beats[0].status, .completed)
        XCTAssertEqual(beats[0].kind, .implementation)
        XCTAssertEqual(beats[0].actionDate, localDayKey(fromISO: "2026-06-23T11:00:00Z"))
    }

    func testActionDateUsesLocalCalendarDay_repro() {
        let messages = [
            NormalizedMessage(role: .user, content: "Ship local-day bucketing", timestamp: "2026-06-23T22:00:00Z"),
            NormalizedMessage(role: .assistant, content: """
            **结果**
            Fixed action_date to local day.
            **验证结果**
            checks run: digest tests
            """, timestamp: "2026-06-23T22:30:00Z"),
        ]
        let beats = ImplementationDigestExtractor.extract(messages: messages, sessionId: "s-local-day", sessionTitle: nil)
        XCTAssertEqual(beats.count, 1)
        XCTAssertEqual(beats[0].actionDate, localDayKey(fromISO: "2026-06-23T22:30:00Z"))
        if let tz = TimeZone(identifier: "Asia/Shanghai"),
           TimeZone.current.secondsFromGMT() == tz.secondsFromGMT(for: Date()) {
            XCTAssertEqual(beats[0].actionDate, "2026-06-24")
        }
    }

    private func localDayKey(fromISO timestamp: String) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let date = fractional.date(from: timestamp) ?? plain.date(from: timestamp)!
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func testCompletionReportWinsOverLaterProgressUpdate() {
        let messages = [
            NormalizedMessage(role: .user, content: "修复 parser drift", timestamp: "2026-06-24T10:00:00Z"),
            NormalizedMessage(role: .assistant, content: "修复完成。\n\n**验证结果**\nchecks run: parser tests", timestamp: "2026-06-24T10:30:00Z"),
            NormalizedMessage(role: .assistant, content: "我再看一眼是否还有日志需要补。", timestamp: "2026-06-24T10:35:00Z"),
        ]

        let beats = ImplementationDigestExtractor.extract(messages: messages, sessionId: "s1", sessionTitle: nil)

        XCTAssertEqual(beats.count, 1)
        XCTAssertTrue(beats[0].assistantOutcome.contains("修复完成"))
        XCTAssertFalse(beats[0].assistantOutcome.contains("我再看一眼"))
        XCTAssertEqual(beats[0].kind, .fix)
    }

    func testMergeDirectiveIsOperationOnlyAndExcludedFromTimeline() {
        let messages = [
            NormalizedMessage(role: .user, content: "给 Timeline 加 work beat 模式", timestamp: "2026-06-25T09:00:00Z"),
            NormalizedMessage(role: .assistant, content: "结果\n已完成 Timeline work beat 模式。\n验证结果\nchecks run: timeline tests", timestamp: "2026-06-25T10:00:00Z"),
            NormalizedMessage(role: .user, content: "合吧", timestamp: "2026-06-25T10:10:00Z"),
            NormalizedMessage(role: .assistant, content: "合并完成。PR #89 已 squash-merge 进 main，CI 全绿。", timestamp: "2026-06-25T10:20:00Z"),
        ]

        let beats = ImplementationDigestExtractor.extract(messages: messages, sessionId: "s1", sessionTitle: nil)
        let timeline = ImplementationTimelineBuilder.build(beats: beats)

        XCTAssertEqual(beats.count, 2)
        XCTAssertEqual(beats[1].status, .operationOnly)
        XCTAssertEqual(beats[1].operationEvents, [.merged, .ciGreen])
        XCTAssertEqual(timeline.count, 1)
        XCTAssertFalse(timeline[0].title.contains("合吧"))
    }

    func testTimelineMergesAdjacentDatesAndSplitsLaterReturn() {
        let beats = [
            SessionImplementationBeat(
                sessionId: "s1",
                beatIndex: 0,
                actionDate: "2026-06-23",
                actionTimestamp: "2026-06-23T10:00:00Z",
                workKey: "fix-parser",
                workTitle: "Fix parser drift",
                humanIntent: "Fix parser drift",
                assistantOutcome: "Fixed parser drift",
                kind: .fix,
                status: .completed,
                operationEvents: [],
                confidence: 0.9
            ),
            SessionImplementationBeat(
                sessionId: "s2",
                beatIndex: 0,
                actionDate: "2026-06-24",
                actionTimestamp: "2026-06-24T10:00:00Z",
                workKey: "fix-parser",
                workTitle: "Fix parser drift",
                humanIntent: "Continue parser drift",
                assistantOutcome: "Added tests",
                kind: .fix,
                status: .completed,
                operationEvents: [],
                confidence: 0.9
            ),
            SessionImplementationBeat(
                sessionId: "s3",
                beatIndex: 0,
                actionDate: "2026-06-27",
                actionTimestamp: "2026-06-27T10:00:00Z",
                workKey: "fix-parser",
                workTitle: "Fix parser drift",
                humanIntent: "Revisit parser drift",
                assistantOutcome: "Fixed remaining edge case",
                kind: .fix,
                status: .completed,
                operationEvents: [],
                confidence: 0.9
            ),
        ]

        let timeline = ImplementationTimelineBuilder.build(beats: beats)

        XCTAssertEqual(timeline.count, 2)
        XCTAssertEqual(timeline[0].startDate, "2026-06-23")
        XCTAssertEqual(timeline[0].endDate, "2026-06-24")
        XCTAssertEqual(timeline[0].batchIndex, 1)
        XCTAssertEqual(timeline[1].startDate, "2026-06-27")
        XCTAssertEqual(timeline[1].endDate, "2026-06-27")
        XCTAssertEqual(timeline[1].batchIndex, 2)
    }
}
