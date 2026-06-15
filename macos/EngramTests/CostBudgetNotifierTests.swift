import XCTest
@testable import Engram

@MainActor
final class CostBudgetNotifierTests: XCTestCase {
    private func makeSettings(
        monitorEnabled: Bool = true,
        notifyOnCostThreshold: Bool = true,
        dailyCostBudget: Double = 0,
        monthlyCostBudget: Double = 0
    ) -> UsagePressureNotificationSettings {
        UsagePressureNotificationSettings(
            monitorEnabled: monitorEnabled,
            notifyOnUsagePressure: true,
            notifyOnCostThreshold: notifyOnCostThreshold,
            dailyCostBudget: dailyCostBudget,
            monthlyCostBudget: monthlyCostBudget
        )
    }

    func testFiresDailyBudgetBreachOncePerDay() {
        let poster = RecordingCostPoster()
        let notifier = UsagePressureNotifier(
            poster: poster,
            settingsProvider: { self.makeSettings(dailyCostBudget: 20) },
            dayKeyProvider: { "2026-06-15" }
        )

        notifier.observeCosts(todayUsd: 25, monthToDateUsd: 25)
        notifier.observeCosts(todayUsd: 27, monthToDateUsd: 27)

        XCTAssertEqual(poster.costPosted.count, 1)
        XCTAssertEqual(poster.costPosted.first?.identity, "daily:2026-06-15")
        XCTAssertTrue(poster.costPosted.first?.message.contains("daily budget") == true)
    }

    func testDoesNotFireBelowBudget() {
        let poster = RecordingCostPoster()
        let notifier = UsagePressureNotifier(
            poster: poster,
            settingsProvider: { self.makeSettings(dailyCostBudget: 20) },
            dayKeyProvider: { "2026-06-15" }
        )

        notifier.observeCosts(todayUsd: 19.99, monthToDateUsd: 19.99)

        XCTAssertTrue(poster.costPosted.isEmpty)
    }

    func testReArmsOnNextDay() {
        let poster = RecordingCostPoster()
        var day = "2026-06-15"
        let notifier = UsagePressureNotifier(
            poster: poster,
            settingsProvider: { self.makeSettings(dailyCostBudget: 20) },
            dayKeyProvider: { day }
        )

        notifier.observeCosts(todayUsd: 25, monthToDateUsd: 25)
        day = "2026-06-16"
        notifier.observeCosts(todayUsd: 25, monthToDateUsd: 25)

        XCTAssertEqual(poster.costPosted.count, 2)
        XCTAssertEqual(poster.costPosted.map(\.identity), ["daily:2026-06-15", "daily:2026-06-16"])
    }

    func testDisabledThresholdDoesNotFireAndClearsDedup() {
        let poster = RecordingCostPoster()
        var threshold = true
        let notifier = UsagePressureNotifier(
            poster: poster,
            settingsProvider: {
                self.makeSettings(notifyOnCostThreshold: threshold, dailyCostBudget: 20)
            },
            dayKeyProvider: { "2026-06-15" }
        )

        notifier.observeCosts(todayUsd: 25, monthToDateUsd: 25)
        XCTAssertEqual(poster.costPosted.count, 1)

        // Disable: no new fire, and dedup state cleared so re-enabling fires again
        // on the same day.
        threshold = false
        notifier.observeCosts(todayUsd: 25, monthToDateUsd: 25)
        XCTAssertEqual(poster.costPosted.count, 1)

        threshold = true
        notifier.observeCosts(todayUsd: 25, monthToDateUsd: 25)
        XCTAssertEqual(poster.costPosted.count, 2)
    }

    func testMonitorDisabledDoesNotFire() {
        let poster = RecordingCostPoster()
        let notifier = UsagePressureNotifier(
            poster: poster,
            settingsProvider: { self.makeSettings(monitorEnabled: false, dailyCostBudget: 20) },
            dayKeyProvider: { "2026-06-15" }
        )

        notifier.observeCosts(todayUsd: 25, monthToDateUsd: 25)

        XCTAssertTrue(poster.costPosted.isEmpty)
    }

    func testZeroBudgetDoesNotFire() {
        let poster = RecordingCostPoster()
        let notifier = UsagePressureNotifier(
            poster: poster,
            settingsProvider: { self.makeSettings(dailyCostBudget: 0, monthlyCostBudget: 0) },
            dayKeyProvider: { "2026-06-15" }
        )

        notifier.observeCosts(todayUsd: 999, monthToDateUsd: 999)

        XCTAssertTrue(poster.costPosted.isEmpty)
    }

    func testMonthlyBudgetBreachWhenDailyUnset() {
        let poster = RecordingCostPoster()
        let notifier = UsagePressureNotifier(
            poster: poster,
            settingsProvider: { self.makeSettings(dailyCostBudget: 0, monthlyCostBudget: 100) },
            dayKeyProvider: { "2026-06-15" }
        )

        notifier.observeCosts(todayUsd: 5, monthToDateUsd: 120)

        XCTAssertEqual(poster.costPosted.count, 1)
        XCTAssertEqual(poster.costPosted.first?.identity, "monthly:2026-06-15")
        XCTAssertTrue(poster.costPosted.first?.message.contains("monthly budget") == true)
    }

    func testUsagePressurePathUnaffectedByCostExtension() {
        let poster = RecordingCostPoster()
        let notifier = UsagePressureNotifier(
            poster: poster,
            settingsProvider: { self.makeSettings(dailyCostBudget: 20) },
            dayKeyProvider: { "2026-06-15" }
        )

        notifier.observe(summary: UsagePressureSummary(
            severity: .critical,
            message: "Usage critical: Codex 5h token pressure 92%"
        ))

        XCTAssertEqual(poster.usagePosted.count, 1)
        XCTAssertTrue(poster.costPosted.isEmpty)
    }
}

@MainActor
private final class RecordingCostPoster: UsagePressureNotificationPosting {
    var usagePosted: [UsagePressureSummary] = []
    var costPosted: [CostBudgetSummary] = []

    func postUsagePressureNotification(_ summary: UsagePressureSummary) {
        usagePosted.append(summary)
    }

    func postCostBudgetNotification(_ summary: CostBudgetSummary) {
        costPosted.append(summary)
    }
}
