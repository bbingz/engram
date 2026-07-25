import XCTest
@testable import Engram

final class PopoverUsageSectionTests: XCTestCase {
    func testUsageGroupsNormalizeSourceCaseAndWhitespace() {
        let items = [
            EngramServiceUsageItem(
                source: " Codex ",
                metric: "5h token total",
                value: 1260,
                unit: "tokens",
                limit: nil,
                resetAt: "2026-04-23T07:00:00Z",
                status: "observed"
            ),
            EngramServiceUsageItem(
                source: "codex",
                metric: "5h token pressure",
                value: 78,
                unit: "%",
                limit: 100,
                resetAt: "2026-04-23T07:00:00Z",
                status: "attention"
            ),
            EngramServiceUsageItem(
                source: "Claude-Code",
                metric: "weekly remaining",
                value: 4,
                unit: "%",
                limit: nil,
                resetAt: "2026-06-08T00:00:00Z",
                status: "critical"
            )
        ]

        let groups = PopoverUsageSection.groupedUsageItemsBySource(items)

        XCTAssertEqual(groups.map(\.source), ["claude-code", "codex"])
        XCTAssertEqual(groups.first { $0.source == "codex" }?.items.map(\.metric).sorted(), [
            "5h token pressure",
            "5h token total",
        ])
    }

    func testUsageWindowSuffixNormalizesMetricCaseAndWhitespace() {
        XCTAssertEqual(PopoverUsageSection.windowSuffix(for: " 5H Token Pressure "), "5h")
        XCTAssertEqual(PopoverUsageSection.windowSuffix(for: "7D cost share"), "7d")
        XCTAssertEqual(PopoverUsageSection.windowSuffix(for: "weekly remaining"), "")
    }

    func testCompactUsagePrefersActionablePressureOverHigherObservedShare() {
        let items = [
            EngramServiceUsageItem(
                source: "codex",
                metric: "7d cost share",
                value: 91,
                unit: "%",
                limit: nil,
                resetAt: nil,
                status: "observed"
            ),
            EngramServiceUsageItem(
                source: "codex",
                metric: "5h token share",
                value: 36.1,
                unit: "%",
                limit: nil,
                resetAt: nil,
                status: "observed"
            ),
            EngramServiceUsageItem(
                source: "codex",
                metric: "5h token total",
                value: 1260,
                unit: "tokens",
                limit: nil,
                resetAt: "2026-04-23T07:00:00Z",
                status: "observed"
            ),
            EngramServiceUsageItem(
                source: "codex",
                metric: "5h window used",
                value: 71,
                unit: "%",
                limit: nil,
                resetAt: "2026-04-23T07:00:00Z",
                status: "attention"
            )
        ]

        let selected = PopoverUsageSection.compactUsageItem(from: items)

        XCTAssertEqual(selected?.metric, "5h window used")
        XCTAssertEqual(selected?.value, 71)
        XCTAssertEqual(selected?.resetAt, "2026-04-23T07:00:00Z")
        XCTAssertEqual(selected?.status, "attention")
    }

    func testCompactUsagePrefersTokenPressureMetricOverObservedShares() {
        let items = [
            EngramServiceUsageItem(
                source: "codex",
                metric: "7d cost share",
                value: 91,
                unit: "%",
                limit: nil,
                resetAt: nil,
                status: "observed"
            ),
            EngramServiceUsageItem(
                source: "codex",
                metric: "5h token total",
                value: 1260,
                unit: "tokens",
                limit: nil,
                resetAt: "2026-04-23T07:00:00Z",
                status: "observed"
            ),
            EngramServiceUsageItem(
                source: "codex",
                metric: "5h token pressure",
                value: 78,
                unit: "%",
                limit: 100,
                resetAt: "2026-04-23T07:00:00Z",
                status: "attention"
            )
        ]

        let selected = PopoverUsageSection.compactUsageItem(from: items)

        XCTAssertEqual(selected?.metric, "5h token pressure")
        XCTAssertEqual(selected?.value, 78)
        XCTAssertEqual(selected?.status, "attention")
    }

    func testCompactUsageNormalizesStatusCaseAndWhitespace() {
        let items = [
            EngramServiceUsageItem(
                source: "claude-code",
                metric: "7d cost share",
                value: 8,
                unit: "%",
                limit: nil,
                resetAt: nil,
                status: " Critical "
            ),
            EngramServiceUsageItem(
                source: "claude-code",
                metric: "5h token pressure",
                value: 72,
                unit: "%",
                limit: 100,
                resetAt: "2026-06-07T10:00:00Z",
                status: "attention"
            )
        ]

        let selected = PopoverUsageSection.compactUsageItem(from: items)

        XCTAssertEqual(selected?.metric, "7d cost share")
        XCTAssertEqual(selected?.status, " Critical ")
    }

    func testCompactUsagePrefersLowestRemainingQuotaWithinSamePriority() {
        let items = [
            EngramServiceUsageItem(
                source: "claude-code",
                metric: "weekly remaining",
                value: 30,
                unit: "%",
                limit: nil,
                resetAt: "2026-06-08T00:00:00Z",
                status: "attention"
            ),
            EngramServiceUsageItem(
                source: "claude-code",
                metric: "5h remaining",
                value: 4,
                unit: "%",
                limit: nil,
                resetAt: "2026-06-07T10:00:00Z",
                status: "attention"
            )
        ]

        let selected = PopoverUsageSection.compactUsageItem(from: items)

        XCTAssertEqual(selected?.metric, "5h remaining")
        XCTAssertEqual(selected?.value, 4)
        XCTAssertEqual(selected?.resetAt, "2026-06-07T10:00:00Z")
    }

    func testUsageMetricFormatsTokenTotalsWithoutPercentSuffix() {
        XCTAssertEqual(
            UsageMetricRow.formattedValue(value: 1260, unit: "tokens", suffix: "5h"),
            "1.3k tok 5h"
        )
        XCTAssertEqual(
            UsageMetricRow.formattedValue(value: 36.1, unit: "%", suffix: "5h"),
            "36% 5h"
        )
    }

    func testUsageMetricFormatsExplicitLimits() {
        XCTAssertEqual(
            UsageMetricRow.formattedValue(value: 91, unit: "%", limit: 100, suffix: "wk"),
            "91.0/100.0% wk"
        )
    }

    func testUsageBarClarifiesRemainingPercentPressure() {
        XCTAssertEqual(
            UsageBar.percentText(label: "weekly remaining", value: 4, limit: nil, suffix: ""),
            "4% (96% used)"
        )
        XCTAssertEqual(
            UsageBar.percentText(label: "Claude Code", value: 4, limit: nil, suffix: "5h", metric: "5h remaining"),
            "4% (96% used) 5h"
        )
    }

    func testUsageBarFillsRemainingQuotaByUsedPressure() {
        XCTAssertEqual(
            UsageBar.fillFraction(value: 4, metric: "5h remaining"),
            0.96,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            UsageBar.fillFraction(value: 71, metric: "5h window used"),
            0.71,
            accuracy: 0.0001
        )
    }

    // row 13 (uiux-polish-a11y): limitless shares route to text, not bars.
    // Fails before isLimitlessShare exists.
    func testLimitlessSharePredicateIsTrue_repro() {
        XCTAssertTrue(
            UsageMetricRow.isLimitlessShare(metric: "7d token share", limit: nil)
        )
        XCTAssertTrue(
            UsageMetricRow.isLimitlessShare(metric: "5h token share", limit: nil)
        )
    }

    // Scoped-predicate guard: remaining/used percent meters stay on the bar branch.
    func testRemainingPercentStaysOnBarBranch_repro() {
        XCTAssertFalse(
            UsageMetricRow.isLimitlessShare(metric: "weekly remaining", limit: nil)
        )
        XCTAssertFalse(
            UsageMetricRow.isLimitlessShare(metric: "5h remaining", limit: nil)
        )
        // A share with an explicit limit is not "limitless".
        XCTAssertFalse(
            UsageMetricRow.isLimitlessShare(metric: "7d token share", limit: 100)
        )
    }

    func testShareTextIsSelfLabeling() {
        XCTAssertEqual(
            UsageMetricRow.shareText(value: 62, metric: "7d token share", suffix: ""),
            "62% of 7d tokens"
        )
        XCTAssertEqual(
            UsageMetricRow.shareText(value: 41, metric: "7d cost share", suffix: ""),
            "41% of 7d cost"
        )
        XCTAssertEqual(
            UsageMetricRow.shareText(value: 30, metric: "5h token share", suffix: ""),
            "30% of 5h tokens"
        )
        XCTAssertEqual(
            UsageMetricRow.shareText(value: 62, metric: "7d token share", suffix: "7d"),
            "62% 7d share"
        )
    }
}
