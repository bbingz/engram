import XCTest
@testable import Engram

final class SourcePulseUsageFormattingTests: XCTestCase {
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

    func testRunwayItemRequiresLocalUsageMetricAndCarriesFreshness() {
        XCTAssertNil(SourcePulseView.runwayItem(from: EngramServiceSourceInfo(name: "codex", sessionCount: 1, latestIndexed: nil)))

        let item = SourcePulseView.runwayItem(from: EngramServiceSourceInfo(
            name: "codex",
            sessionCount: 1,
            latestIndexed: nil,
            latestUsageMetric: "weekly quota pressure",
            latestUsageValue: 91,
            latestUsageUnit: "%",
            latestUsageLimitValue: 100,
            latestUsageResetAt: "2026-04-30T00:00:00Z",
            latestUsageCollectedAt: "2026-04-23T02:06:00Z",
            latestUsageStatus: "critical"
        ))

        XCTAssertEqual(item?.source, "codex")
        XCTAssertEqual(item?.metric, "weekly quota pressure")
        XCTAssertEqual(item?.collectedAt, "2026-04-23T02:06:00Z")
        XCTAssertEqual(item?.dataSourceLabel, "local usage snapshots")
    }

    func testRunwayEmptyStateDoesNotImplyProviderCredentialOrNetworkReads() throws {
        let sourcePath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Engram/Views/Pages/SourcePulseView.swift")
        let source = try String(contentsOf: sourcePath)

        XCTAssertTrue(source.contains("Engram does not read provider credentials or call provider APIs by default"))
        XCTAssertTrue(source.contains("local usage snapshots"))
    }

    func testRunwayRowsExposeStableAccessibilityIdentifiers() throws {
        let sourcePath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Engram/Views/Pages/SourcePulseView.swift")
        let source = try String(contentsOf: sourcePath)

        XCTAssertTrue(source.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"sourcePulse_runwayRow_\\(item.source)\")"))
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
