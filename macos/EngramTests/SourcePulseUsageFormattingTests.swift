import XCTest
@testable import Engram

final class SourcePulseUsageFormattingTests: XCTestCase {
    private func utcDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int = 0,
        _ second: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return components.date!
    }

    func testSourceFreshnessClassifiesFreshAgingAndStaleBoundaries() {
        let now = utcDate(2026, 7, 7, 12)

        XCTAssertEqual(SourceIndexFreshness.classify("2026-07-06 12:00:00", now: now), .fresh)
        XCTAssertEqual(SourceIndexFreshness.classify("2026-07-06 11:59:59", now: now), .aging)
        XCTAssertEqual(SourceIndexFreshness.classify("2026-06-30 12:00:00", now: now), .aging)
        XCTAssertEqual(SourceIndexFreshness.classify("2026-06-30 11:59:59", now: now), .stale)
    }

    func testSourceFreshnessClassifiesNilGarbageAndFutureTimestamp() {
        let now = utcDate(2026, 7, 7, 12)

        XCTAssertEqual(SourceIndexFreshness.classify(nil, now: now), .unknown)
        XCTAssertEqual(SourceIndexFreshness.classify("not-a-date", now: now), .unknown)
        XCTAssertEqual(SourceIndexFreshness.classify("2026-07-07 12:05:00", now: now), .fresh)
    }

    func testSourceFreshnessRelativeAgeText() {
        let now = utcDate(2026, 7, 7, 12)

        XCTAssertEqual(SourceIndexFreshness.relativeAgeText("2026-07-07 11:58:00", now: now), "2m ago")
        XCTAssertEqual(SourceIndexFreshness.relativeAgeText("2026-07-07 10:00:00", now: now), "2h ago")
        XCTAssertEqual(SourceIndexFreshness.relativeAgeText("2026-07-02 12:00:00", now: now), "5d ago")
        XCTAssertEqual(SourceIndexFreshness.relativeAgeText("2026-07-07 12:05:00", now: now), "just now")
        XCTAssertEqual(SourceIndexFreshness.relativeAgeText(nil, now: now), "Unknown")
    }

    func testUsagePillTextFormatsTokenTotalsCompactly() {
        XCTAssertEqual(
            SourcePulseView.usagePillText(metric: "5h token total", value: 1260, unit: "tokens"),
            "5h token total 1.3k tok"
        )
    }

    func testUsagePillTextFormatsPercentMetricsWithPercentSign() {
        XCTAssertEqual(
            SourcePulseView.usagePillText(metric: "5h token share", value: 36.1, unit: "%"),
            "5h token share 36.1%"
        )
    }

    func testUsagePillTextFormatsExplicitLimits() {
        XCTAssertEqual(
            SourcePulseView.usagePillText(metric: "weekly quota pressure", value: 91, unit: "%", limit: 100),
            "weekly quota pressure 91.0/100.0%"
        )
    }

    func testUsagePillTextClarifiesRemainingPercentPressure() {
        XCTAssertEqual(
            SourcePulseView.usagePillText(metric: "weekly remaining", value: 4, unit: "%"),
            "weekly remaining 4% (96% used)"
        )
    }

    func testUsagePillTextClarifiesLegacyRemainingPercentWithoutUnit() {
        XCTAssertEqual(
            SourcePulseView.usagePillText(metric: "weekly remaining", value: 4, unit: nil),
            "weekly remaining 4% (96% used)"
        )
    }

    func testTokenCoveragePillTextClampsPercent() {
        XCTAssertEqual(SourcePulseView.tokenCoveragePillText(35), "Tokens 35%")
        XCTAssertEqual(SourcePulseView.tokenCoveragePillText(-5), "Tokens 0%")
        XCTAssertEqual(SourcePulseView.tokenCoveragePillText(123), "Tokens 100%")
    }

    func testHealthBadgeMapsCriticalStatusToRed() throws {
        let sourcePath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Engram/Views/Pages/SourcePulseView.swift")
        let source = try String(contentsOf: sourcePath)
        let healthBadgeStart = try XCTUnwrap(source.range(of: "private func healthBadge"))
        let healthBadgeEnd = try XCTUnwrap(source.range(of: "private func usageColor"))
        let healthBadgeSource = String(source[healthBadgeStart.lowerBound..<healthBadgeEnd.lowerBound])

        XCTAssertTrue(
            healthBadgeSource.contains("case \"critical\": .red"),
            "SourcePulseView should render critical source health with red urgency instead of falling back to gray."
        )
    }

    func testUsageStatusNormalizesCaseAndWhitespaceForUrgencyColors() throws {
        XCTAssertEqual(SourcePulseView.normalizedUsageStatusForDisplay(" Critical "), "critical")
        XCTAssertEqual(SourcePulseView.normalizedUsageStatusForDisplay(" ATTENTION\n"), "attention")
        XCTAssertNil(SourcePulseView.normalizedUsageStatusForDisplay("  "))

        let sourcePath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Engram/Views/Pages/SourcePulseView.swift")
        let source = try String(contentsOf: sourcePath)
        let usageColorStart = try XCTUnwrap(source.range(of: "private func usageColor"))
        let usageColorEnd = try XCTUnwrap(source.range(of: "@ViewBuilder\n    private func factPill"))
        let usageColorSource = String(source[usageColorStart.lowerBound..<usageColorEnd.lowerBound])

        XCTAssertTrue(
            usageColorSource.contains("Self.normalizedUsageStatusForDisplay(status)"),
            "SourcePulse usage urgency colors should normalize status strings like the usage popover and status store."
        )
    }
}
