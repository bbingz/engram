import XCTest
@testable import Engram

@MainActor
final class UsagePressureNotifierTests: XCTestCase {
    func testPostsUsagePressureWhenEnabled() {
        let poster = RecordingUsagePressureNotificationPoster()
        let notifier = UsagePressureNotifier(
            poster: poster,
            settingsProvider: { UsagePressureNotificationSettings(monitorEnabled: true, notifyOnUsagePressure: true) }
        )

        notifier.observe(summary: UsagePressureSummary(
            severity: .critical,
            message: "Usage critical: Codex 5h token pressure 92%"
        ))

        XCTAssertEqual(poster.posted, [
            UsagePressureSummary(
                severity: .critical,
                message: "Usage critical: Codex 5h token pressure 92%"
            )
        ])
    }

    func testDoesNotRepeatSamePressureAlertUntilItClears() {
        let poster = RecordingUsagePressureNotificationPoster()
        let notifier = UsagePressureNotifier(
            poster: poster,
            settingsProvider: { UsagePressureNotificationSettings(monitorEnabled: true, notifyOnUsagePressure: true) }
        )
        let summary = UsagePressureSummary(
            severity: .critical,
            message: "Usage critical: Codex 5h token pressure 92%"
        )

        notifier.observe(summary: summary)
        notifier.observe(summary: summary)
        notifier.observe(summary: nil)
        notifier.observe(summary: summary)

        XCTAssertEqual(poster.posted, [summary, summary])
    }

    func testDoesNotRepeatSamePressureIdentityWhenMessageChanges() {
        let poster = RecordingUsagePressureNotificationPoster()
        let notifier = UsagePressureNotifier(
            poster: poster,
            settingsProvider: { UsagePressureNotificationSettings(monitorEnabled: true, notifyOnUsagePressure: true) }
        )
        let first = UsagePressureSummary(
            severity: .attention,
            identity: "codex:5h token pressure",
            message: "Usage attention: Codex 5h token pressure 78.0/100.0% · resets 2026-06-07 10:00 UTC"
        )
        let samePressureNewReset = UsagePressureSummary(
            severity: .attention,
            identity: "codex:5h token pressure",
            message: "Usage attention: Codex 5h token pressure 78.0/100.0% · resets 2026-06-07 11:00 UTC"
        )

        notifier.observe(summary: first)
        notifier.observe(summary: samePressureNewReset)

        XCTAssertEqual(poster.posted, [first])
    }

    func testPostsAgainWhenSamePressureIdentityEscalatesSeverity() {
        let poster = RecordingUsagePressureNotificationPoster()
        let notifier = UsagePressureNotifier(
            poster: poster,
            settingsProvider: { UsagePressureNotificationSettings(monitorEnabled: true, notifyOnUsagePressure: true) }
        )
        let attention = UsagePressureSummary(
            severity: .attention,
            identity: "codex:5h token pressure",
            message: "Usage attention: Codex 5h token pressure 78.0/100.0%"
        )
        let critical = UsagePressureSummary(
            severity: .critical,
            identity: "codex:5h token pressure",
            message: "Usage critical: Codex 5h token pressure 92.0/100.0%"
        )

        notifier.observe(summary: attention)
        notifier.observe(summary: critical)

        XCTAssertEqual(poster.posted, [attention, critical])
    }

    func testDoesNotPostWhenMonitorOrUsageNotificationsAreDisabled() {
        let summary = UsagePressureSummary(
            severity: .attention,
            message: "Usage attention: OpenCode weekly token pressure 78%"
        )
        let disabledMonitorPoster = RecordingUsagePressureNotificationPoster()
        let disabledUsagePoster = RecordingUsagePressureNotificationPoster()

        UsagePressureNotifier(
            poster: disabledMonitorPoster,
            settingsProvider: { UsagePressureNotificationSettings(monitorEnabled: false, notifyOnUsagePressure: true) }
        ).observe(summary: summary)
        UsagePressureNotifier(
            poster: disabledUsagePoster,
            settingsProvider: { UsagePressureNotificationSettings(monitorEnabled: true, notifyOnUsagePressure: false) }
        ).observe(summary: summary)

        XCTAssertTrue(disabledMonitorPoster.posted.isEmpty)
        XCTAssertTrue(disabledUsagePoster.posted.isEmpty)
    }

    func testDisabledSettingsClearDeduplicationSoReenabledPressureCanNotify() {
        var settings = UsagePressureNotificationSettings(monitorEnabled: true, notifyOnUsagePressure: true)
        let poster = RecordingUsagePressureNotificationPoster()
        let notifier = UsagePressureNotifier(
            poster: poster,
            settingsProvider: { settings }
        )
        let summary = UsagePressureSummary(
            severity: .attention,
            identity: "codex:5h token pressure",
            message: "Usage attention: Codex 5h token pressure 78.0/100.0%"
        )

        notifier.observe(summary: summary)
        settings = UsagePressureNotificationSettings(monitorEnabled: true, notifyOnUsagePressure: false)
        notifier.observe(summary: summary)
        settings = UsagePressureNotificationSettings(monitorEnabled: true, notifyOnUsagePressure: true)
        notifier.observe(summary: summary)

        XCTAssertEqual(poster.posted, [summary, summary])
    }
}

@MainActor
private final class RecordingUsagePressureNotificationPoster: UsagePressureNotificationPosting {
    var posted: [UsagePressureSummary] = []

    func postUsagePressureNotification(_ summary: UsagePressureSummary) {
        posted.append(summary)
    }
}
